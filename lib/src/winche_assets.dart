import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:winche_core/winche_core.dart';

import 'glob.dart';
import 'open_store.dart';
import 'store.dart';

/// Reading assets failed. [code] is `notFound` (no such path in the release, or the rules don't let you see it),
/// `permissionDenied`, `unavailable` (offline, and not kept on this device) or `dataLoss` (a download didn't match
/// its hash).
final class WincheAssetsException extends WincheException {
  /// Creates an exception.
  const WincheAssetsException(super.code, super.message, {this.status});

  /// The HTTP status, when there was an answer.
  final int? status;

  factory WincheAssetsException._from(WincheHttpException e) => WincheAssetsException(e.code, e.message, status: e.status);
}

/// How [WincheAssets] syncs and keeps assets. Set it before the first use.
final class WincheAssetsSettings {
  /// Creates settings.
  const WincheAssetsSettings({
    this.channel = 'production',
    this.prefetch = const [],
    this.maxCacheBytes = 512 * 1024 * 1024,
    this.concurrentDownloads = 3,
  });

  /// The channel to follow (`production`, `beta`, one per app version…).
  final String channel;

  /// Paths downloaded by [WincheAssets.sync] so they're there offline from the start (`translations/**`,
  /// `pages/*.html`, `**/*.json`). Everything else is downloaded on first use, then kept too.
  final List<String> prefetch;

  /// How much the device keeps. Past it, contents no longer in the release go first, then the least recently used
  /// that aren't prefetched; prefetched ones of the current release are always kept.
  final int maxCacheBytes;

  /// How many files [WincheAssets.sync] downloads at once.
  final int concurrentDownloads;
}

/// A file of the release: where it is in the folder, its content's SHA-256, size and type.
final class AssetEntry {
  /// Creates an entry.
  const AssetEntry({required this.path, required this.hash, required this.size, required this.mimeType});

  /// Its path in the assets folder, e.g. `translations/en.json`.
  final String path;

  /// Its content's SHA-256 (lowercase hex): the same in every release where it didn't change.
  final String hash;

  /// Its size in bytes.
  final int size;

  /// Its type, e.g. `application/json`.
  final String mimeType;

  Map<String, Object?> _toJson() => {'path': path, 'hash': hash, 'size': size, 'mimeType': mimeType};

  static AssetEntry _fromJson(Map<String, Object?> j) =>
      AssetEntry(path: j['path']! as String, hash: j['hash']! as String, size: (j['size']! as num).toInt(), mimeType: j['mimeType'] as String? ?? '');
}

/// The release a channel points at, as you may see it (the files the rules let you list).
final class AssetRelease {
  /// Creates a release.
  AssetRelease({required this.channel, required this.number, required this.publishedAt, required List<AssetEntry> files})
      : files = List.unmodifiable(files),
        _byPath = {for (final f in files) f.path: f};

  /// The channel it came from.
  final String channel;

  /// Its number: higher is newer.
  final int number;

  /// When it was published.
  final DateTime publishedAt;

  /// Its files, by path.
  final List<AssetEntry> files;

  final Map<String, AssetEntry> _byPath;

  /// The file at [path], or null.
  AssetEntry? operator [](String path) => _byPath[path];

  /// The paths matching [pattern] (`translations/*.json`).
  List<String> pathsMatching(String pattern) => [for (final f in files) if (matchesPattern(pattern, f.path)) f.path];
}

/// An asset's bytes on this device.
final class AssetFile {
  /// Creates one.
  const AssetFile({required this.entry, required this.localPath});

  /// Which file of the release it is.
  final AssetEntry entry;

  /// Where its bytes are on this device. Read it, don't change it: it's shared by every release using it.
  final String localPath;
}

/// An app's assets from a Winche server (`/assets/v1`): the release a channel points at, kept on the device.
///
/// ```dart
/// final assets = WincheAssets.instance
///   ..settings = const WincheAssetsSettings(channel: 'production', prefetch: ['translations/**']);
/// await assets.sync();                                   // the release, and translations ahead of use
/// final en = await assets.json('translations/en.json');  // from the device from now on, offline too
/// final video = await assets.file('videos/intro.mp4');   // downloaded on first use, then kept
/// ```
///
/// Requests carry the signed-in user's token (the server's rules decide what each user may list and read); signed
/// out, they go without one. What's listed is kept per user, and contents once (by hash) for everyone, in
/// `assets/` of the app's folder (`WincheOptions.directoryResolver`; memory on the web or without one).
final class WincheAssets extends WincheService implements WincheSessionConsumer {
  /// Registers with [app]; use [instance] or [instanceFor] instead.
  WincheAssets(super.app);

  /// The assets client of the default app.
  static WincheAssets get instance => instanceFor(Winche.app);

  /// The assets client of [app].
  static WincheAssets instanceFor(WincheApp app) => WincheService.instanceFor(app, () => WincheAssets(app));

  /// The service's id in `WincheOptions.endpoints`.
  static const serviceId = 'assets';

  WincheAssetsSettings _settings = const WincheAssetsSettings();
  bool _used = false;

  /// How assets are synced and kept. Can't change once they've been used.
  WincheAssetsSettings get settings => _settings;

  set settings(WincheAssetsSettings value) {
    if (_used) throw StateError('WincheAssets.settings can only be set before the first use.');
    _settings = value;
  }

  /// How long one request may take.
  Duration timeout = const Duration(seconds: 60);

  AssetStore? _store;
  Future<AssetStore>? _opening;
  AssetRelease? _release;
  String? _etag;
  String? _loadedFor;
  WincheSession? _session;
  bool _synced = false;
  final _inFlight = <String, Future<void>>{};
  final _releases = StreamController<AssetRelease>.broadcast();

  /// The release in use: synced, or kept from the last sync. Null before the first.
  AssetRelease? get release => _release;

  /// Each release as it's taken up (a sync that found a new one, or a switch of user).
  Stream<AssetRelease> get releases => _releases.stream;

  Uri get _endpoint => (app.options ?? const WincheOptions()).endpointFor(serviceId, path: '/assets/v1');

  Uri _url(String path, [Map<String, String>? query]) {
    final base = _endpoint;
    return base.replace(path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/$path', queryParameters: query);
  }

  String get _who => _session?.identity.storageKey ?? 'signed-out';
  String get _listingRecord => 'listing-$_who-${_settings.channel}';

  Future<AssetStore> _open() async {
    _used = true;
    if (_store != null) return _store!;
    return _opening ??= () async {
      final root = app.options?.directoryResolver;
      final store = openAssetStore(root == null ? null : '${await root()}/assets');
      return _store = store;
    }();
  }

  /// The kept listing for whoever is signed in, when it isn't loaded yet.
  Future<void> _load() async {
    if (_loadedFor == _listingRecord) return;
    final store = await _open();
    final key = _listingRecord;
    final saved = await store.readRecord(key);
    _loadedFor = key;
    if (saved == null) {
      _release = null;
      _etag = null;
      return;
    }
    _etag = saved['etag'] as String?;
    _release = AssetRelease(
      channel: _settings.channel,
      number: (saved['release']! as num).toInt(),
      publishedAt: DateTime.parse(saved['publishedAt']! as String),
      files: [for (final f in saved['files']! as List<Object?>) AssetEntry._fromJson(f! as Map<String, Object?>)],
    );
    _releases.add(_release!);
  }

  // ----- the session ---------------------------------------------------------------------------

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    _session = session;
    _loadedFor = null;   // another user may see other files: their own listing
    if (!_used) return;
    await _load();
    if (_synced) unawaited(sync().then((_) {}, onError: (Object _) {}));
  }

  @override
  Future<void> onTokenChanged() async {}

  // ----- sync ----------------------------------------------------------------------------------

  /// Gets the channel's release (only when it changed: the server answers 304 otherwise), keeps it, and downloads
  /// the [WincheAssetsSettings.prefetch] files not on the device yet. Offline it throws `unavailable`, and what was
  /// kept from the last sync stays in use.
  Future<AssetRelease> sync() async {
    _check();
    await _load();
    final key = _listingRecord;
    final session = _session;
    WincheResponse response;
    try {
      response = await app.http.send(WincheRequest.get(
        _url('channels/${Uri.encodeComponent(_settings.channel)}'),
        headers: {'if-none-match': ?_etag},
        timeout: timeout,
        service: serviceId,
        session: session,
      ));
    } on WincheHttpException catch (e) {
      if (e.status != 304 || _release == null) throw WincheAssetsException._from(e);
      response = WincheResponse(304, const {}, const []);
    }
    if (_loadedFor != key) return sync();   // the user changed while it was asked: theirs instead
    _synced = true;
    if (response.status != 304) {
      final body = response.json! as Map<String, Object?>;
      final release = AssetRelease(
        channel: _settings.channel,
        number: (body['release']! as num).toInt(),
        publishedAt: DateTime.parse(body['publishedAt']! as String),
        files: [for (final f in body['files']! as List<Object?>) AssetEntry._fromJson(f! as Map<String, Object?>)],
      );
      final changed = _release == null || _release!.number != release.number || response.headers['etag'] != _etag;
      _release = release;
      _etag = response.headers['etag'];
      await (await _open()).writeRecord(key, {
        'etag': _etag,
        'release': release.number,
        'publishedAt': release.publishedAt.toIso8601String(),
        'files': [for (final f in release.files) f._toJson()],
      });
      if (changed) _releases.add(release);
    }
    final release = _release!;
    final wanted = [for (final f in release.files) if (_prefetched(f.path)) f];
    final queue = [for (final f in wanted) if (!await (await _open()).hasContent(f.hash)) f];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await _fetch(release, queue.removeLast());
      }
    }
    await Future.wait([for (var i = 0; i < _settings.concurrentDownloads; i++) worker()]);
    await _trim();
    return release;
  }

  bool _prefetched(String path) => _settings.prefetch.any((p) => matchesPattern(p, path));

  // ----- reads ---------------------------------------------------------------------------------

  /// Whether the release has [path] (that you may see).
  Future<bool> has(String path) async => (await _current())[path] != null;

  /// The paths in the release, or those matching [pattern] (`translations/*.json`).
  Future<List<String>> paths([String pattern = '**']) async => (await _current()).pathsMatching(pattern);

  /// [path]'s bytes: from the device, or downloaded (and kept) on first use.
  Future<Uint8List> bytes(String path) async {
    final entry = await _entry(path);
    final store = await _open();
    final bytes = await store.readContent(entry.hash);
    if (bytes != null) {
      await _touch(entry.hash);
      return bytes;
    }
    await _fetch(_release!, entry);
    return (await store.readContent(entry.hash))!;
  }

  /// [path] as UTF-8 text.
  Future<String> text(String path) async => utf8.decode(await bytes(path));

  /// [path] decoded from JSON.
  Future<Object?> json(String path) async => jsonDecode(await text(path));

  /// [path] as a file on this device (for players and viewers that take a path). Needs a folder
  /// (`WincheOptions.directoryResolver`): not on the web.
  Future<AssetFile> file(String path) async {
    final entry = await _entry(path);
    final store = await _open();
    if (!store.durable) {
      throw UnsupportedError('Assets are kept in memory here (the web, or no directoryResolver): read them with bytes().');
    }
    if (!await store.hasContent(entry.hash)) await _fetch(_release!, entry);
    await _touch(entry.hash);
    return AssetFile(entry: entry, localPath: (await store.contentPath(entry.hash))!);
  }

  /// Whether [path]'s bytes are on this device (so reading it works offline).
  Future<bool> isKept(String path) async {
    final entry = (await _current())[path];
    return entry != null && await (await _open()).hasContent(entry.hash);
  }

  /// The bytes kept on this device, all users and releases together.
  Future<int> keptBytes() async => (await (await _open()).contents()).values.fold<int>(0, (a, b) => a + b);

  /// Forgets everything kept on this device (listings and contents); the next read syncs again.
  Future<void> clearCache() async {
    await (await _open()).clear();
    _release = null;
    _etag = null;
    _loadedFor = null;
    _synced = false;
  }

  Future<AssetRelease> _current() async {
    _check();
    await _load();
    return _release ?? await sync();
  }

  Future<AssetEntry> _entry(String path) async {
    final release = await _current();
    return release[path] ??
        (throw WincheAssetsException(WincheErrorCode.notFound,
            "There's no $path in release ${release.number} of ${release.channel} (or the rules don't let you see it)."));
  }

  // ----- downloads ------------------------------------------------------------------------------

  /// Downloads [entry]'s content once, however many ask for it at the same time.
  Future<void> _fetch(AssetRelease release, AssetEntry entry) =>
      _inFlight[entry.hash] ??= _download(release, entry).whenComplete(() {
        _inFlight.remove(entry.hash);   // not returned: it's this very future, which would wait on itself
      });

  Future<void> _download(AssetRelease release, AssetEntry entry) async {
    final store = await _open();
    final file = 'releases/${release.number}/files/${entry.path.split('/').map(Uri.encodeComponent).join('/')}';
    try {
      // The signed link to wherever the server keeps it, fetched without our token; or the bytes from the server.
      final link = (await app.http.send(WincheRequest.get(_url(file, {'link': 'true'}),
              timeout: timeout, service: serviceId, session: _session)))
          .json! as Map<String, Object?>;
      final url = link['url'] as String?;
      final streamed = await app.http.stream(url != null
          ? WincheRequest.get(Uri.parse(url), auth: WincheRequestAuth.none, timeout: timeout * 10, service: serviceId)
          : WincheRequest.get(_url(file), timeout: timeout * 10, service: serviceId, session: _session));
      await store.writeContent(entry.hash, streamed.body, (_, digest) {
        if (digest != entry.hash) {
          throw WincheAssetsException(WincheErrorCode.dataLoss, '${entry.path} arrived different from what was published (incomplete?).');
        }
      });
    } on WincheHttpException catch (e) {
      throw WincheAssetsException._from(e);
    }
    await _touch(entry.hash);
  }

  // ----- what's kept ---------------------------------------------------------------------------

  Map<String, Object?>? _usage;

  Future<void> _saving = Future.value();

  Future<void> _touch(String hash) async {
    final store = await _open();
    final usage = _usage ??= await store.readRecord('usage') ?? {};
    usage[hash] = DateTime.now().millisecondsSinceEpoch;
    await _saveUsage(store, usage);
  }

  /// One write of the usage record at a time, each of it as it is then.
  Future<void> _saveUsage(AssetStore store, Map<String, Object?> usage) =>
      _saving = _saving.then((_) => store.writeRecord('usage', Map.of(usage)), onError: (Object _) => store.writeRecord('usage', Map.of(usage)));

  /// Keeps the device under [WincheAssetsSettings.maxCacheBytes]: contents no release in use has go first, then the
  /// least recently used that aren't prefetched.
  Future<void> _trim() async {
    final store = await _open();
    final kept = await store.contents();
    var total = kept.values.fold<int>(0, (a, b) => a + b);
    if (total <= _settings.maxCacheBytes) return;
    final usage = _usage ??= await store.readRecord('usage') ?? {};
    final current = {for (final f in _release?.files ?? const <AssetEntry>[]) f.hash: f};
    int used(String h) => (usage[h] as num?)?.toInt() ?? 0;
    final candidates = kept.keys.where((h) => !(current[h] != null && _prefetched(current[h]!.path))).toList()
      ..sort((a, b) {
        final byRelease = (current.containsKey(a) ? 1 : 0) - (current.containsKey(b) ? 1 : 0);
        return byRelease != 0 ? byRelease : used(a) - used(b);
      });
    for (final hash in candidates) {
      if (total <= _settings.maxCacheBytes) break;
      if (_inFlight.containsKey(hash)) continue;
      await store.deleteContent(hash);
      usage.remove(hash);
      total -= kept[hash]!;
    }
    await _saveUsage(store, usage);
  }

  void _check() {
    if (isDisposed) throw StateError('This WincheAssets has been disposed.');
  }

  @override
  Future<void> dispose() async {
    await _releases.close();
    await super.dispose();
  }
}
