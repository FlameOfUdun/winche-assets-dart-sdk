import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:winche_assets/src/glob.dart';
import 'package:winche_assets/winche_assets.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();

/// A server with channels and contents, as `/assets/v1` answers; [link] makes file reads hand out a signed link.
class _Server {
  final contents = <String, String>{};   // hash → text
  final listings = <String, Map<String, String>>{};   // who ('' signed out, else the token) → path → text
  var release = 1;
  var link = false;
  var offline = false;
  final requests = <http.Request>[];

  void publish(Map<String, String> files, {String who = ''}) {
    for (final t in files.values) {
      contents[_hash(t)] = t;
    }
    listings[who] = files;
  }

  String get etag => '"$release-${listings.length}"';

  MockClient get client => MockClient((r) async {
        requests.add(r);
        if (offline) throw http.ClientException('offline');
        final who = (r.headers['authorization'] ?? '').contains('staff') ? 'staff' : '';
        final path = r.url.path;
        if (r.url.host == 'bucket.example.com') return http.Response(contents[path.substring(1)]!, 200);
        if (path.startsWith('/assets/v1/channels/')) {
          final files = listings[who] ?? listings['']!;
          final tag = '"$release-${files.keys.join(',')}"';
          if (r.headers['if-none-match'] == tag) return http.Response('', 304);
          return http.Response(
              jsonEncode({
                'channel': 'production', 'release': release, 'publishedAt': '2026-11-16T10:00:00Z',
                'files': [for (final e in files.entries) {'path': e.key, 'hash': _hash(e.value), 'size': utf8.encode(e.value).length, 'mimeType': 'application/json'}],
              }),
              200,
              headers: {'etag': tag});
        }
        final m = RegExp(r'^/assets/v1/releases/(\d+)/files/(.+)$').firstMatch(path)!;
        final file = Uri.decodeComponent(m.group(2)!);
        final text = (listings[who] ?? listings['']!)[file];
        if (text == null) return http.Response(jsonEncode({'error': {'code': 'not-found', 'message': 'no'}}), 404);
        if (r.url.queryParameters['link'] == 'true') {
          return http.Response(jsonEncode({'url': link ? 'https://bucket.example.com/${_hash(text)}' : null}), 200);
        }
        return http.Response(text, 200);
      });

  List<String> get paths => [for (final r in requests) r.url.path + (r.url.query.isEmpty ? '' : '?${r.url.query}')];
}

void main() {
  late _Server server;
  late Directory dir;
  late WincheApp app;
  var n = 0;

  WincheAssets start({WincheAssetsSettings settings = const WincheAssetsSettings(), bool withDirectory = true}) {
    app = Winche.initializeApp(
      name: 'assets-${n++}',
      options: WincheOptions(baseUrl: Uri.parse('https://api.example.com'), directoryResolver: withDirectory ? () async => dir.path : null),
    );
    app.http.useClient(server.client);
    return WincheAssets.instanceFor(app)..settings = settings;
  }

  setUp(() {
    server = _Server()..publish({'translations/en.json': '{"hi":"Hi"}', 'translations/de.json': '{"hi":"Hallo"}', 'videos/intro.mp4': 'VIDEO'});
    dir = Directory.systemTemp.createTempSync('winche-assets-');
  });
  tearDown(() async {
    await Winche.deinitializeAll();
    dir.deleteSync(recursive: true);
  });

  test('sync takes the release and prefetches; reads come from the device after', () async {
    final assets = start(settings: const WincheAssetsSettings(prefetch: ['translations/**']));
    final release = await assets.sync();
    expect(release.number, 1);
    expect(await assets.paths('translations/*'), ['translations/en.json', 'translations/de.json']);
    expect(server.paths.where((p) => p.contains('/files/')).length, 4);   // two links, two downloads: no video
    server.requests.clear();
    expect(await assets.json('translations/de.json'), {'hi': 'Hallo'});
    expect(server.requests, isEmpty);
    expect(await assets.isKept('videos/intro.mp4'), isFalse);
    expect(await assets.text('videos/intro.mp4'), 'VIDEO');   // on first use
    expect(await assets.isKept('videos/intro.mp4'), isTrue);
    final f = await assets.file('videos/intro.mp4');
    expect(File(f.localPath).readAsStringSync(), 'VIDEO');
  });

  test('a second sync asks with the release it has and takes a 304', () async {
    final assets = start();
    await assets.sync();
    final seen = <int>[];
    assets.releases.listen((r) => seen.add(r.number));
    await assets.sync();
    expect(server.requests.last.headers['if-none-match'], isNotNull);
    server.release = 2;
    server.publish({'translations/en.json': '{"hi":"Hello"}'});
    expect((await assets.sync()).number, 2);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [2]);
    expect(await assets.has('videos/intro.mp4'), isFalse);
    await expectLater(assets.bytes('videos/intro.mp4'), throwsA(isA<WincheAssetsException>().having((e) => e.code, 'code', WincheErrorCode.notFound)));
  });

  test("signed links are fetched without the user's token", () async {
    server.link = true;
    final auth = ScriptedAuthService(app = Winche.initializeApp(name: 'linked', options: WincheOptions(baseUrl: Uri.parse('https://api.example.com'))));
    app.http.useClient(server.client);
    final assets = WincheAssets.instanceFor(app);
    auth.announce(WincheIdentity('u1'));
    await Future<void>.delayed(Duration.zero);
    expect(await assets.text('translations/en.json'), '{"hi":"Hi"}');
    final toBucket = server.requests.singleWhere((r) => r.url.host == 'bucket.example.com');
    expect(toBucket.headers['authorization'], isNull);
    expect(server.requests.first.headers['authorization'], isNotNull);
  });

  test("a download that doesn't match its hash isn't kept", () async {
    final assets = start();
    await assets.sync();
    server.listings['']!['videos/intro.mp4'] = 'TAMPERED';   // the listing still names the old hash
    await expectLater(assets.bytes('videos/intro.mp4'), throwsA(isA<WincheAssetsException>().having((e) => e.code, 'code', WincheErrorCode.dataLoss)));
    expect(await assets.isKept('videos/intro.mp4'), isFalse);
  });

  test('offline, what was kept is read; what wasn\'t says unavailable', () async {
    var assets = start(settings: const WincheAssetsSettings(prefetch: ['translations/**']));
    await assets.sync();
    await Winche.deinitializeAll();
    server.offline = true;
    assets = start(settings: const WincheAssetsSettings(prefetch: ['translations/**']));   // a restart, offline
    await expectLater(assets.sync(), throwsA(isA<WincheAssetsException>().having((e) => e.code, 'code', WincheErrorCode.unavailable)));
    expect(assets.release?.number, 1);
    expect(await assets.json('translations/en.json'), {'hi': 'Hi'});
    await expectLater(assets.bytes('videos/intro.mp4'), throwsA(isA<WincheAssetsException>().having((e) => e.code, 'code', WincheErrorCode.unavailable)));
  });

  test('each user has their own listing; switching takes theirs', () async {
    server.publish({'translations/en.json': '{"hi":"Hi"}', 'staff/guide.html': '<p>staff</p>'}, who: 'staff');
    app = Winche.initializeApp(name: 'users', options: WincheOptions(baseUrl: Uri.parse('https://api.example.com'), directoryResolver: () async => dir.path));
    app.http.useClient(server.client);
    final auth = ScriptedAuthService(app);
    final assets = WincheAssets.instanceFor(app);
    await assets.sync();
    expect(await assets.has('staff/guide.html'), isFalse);
    auth.announce(WincheIdentity('staff1'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await assets.has('staff/guide.html'), isTrue);
    expect(await assets.text('staff/guide.html'), '<p>staff</p>');
  });

  test('past the budget, contents no longer released go first; prefetched ones stay', () async {
    final assets = start(settings: const WincheAssetsSettings(prefetch: ['translations/**'], maxCacheBytes: 40));
    await assets.sync();
    await assets.bytes('videos/intro.mp4');
    server.release = 2;
    server.publish({'translations/en.json': '{"hi":"Hello there"}', 'translations/de.json': '{"hi":"Hallo"}'});
    await assets.sync();
    // Kept were the old en.json (11), the video (5), the new en.json (20) and de.json (14): 50 bytes. Neither old one is
    // released now; the least recently used of them (the old en.json) goes, which is enough. The prefetched ones stay.
    expect(await assets.keptBytes(), 39);
    expect(await assets.isKept('translations/en.json'), isTrue);
    expect(await assets.isKept('translations/de.json'), isTrue);
  });

  test('without a folder, assets are kept in memory and file() says so', () async {
    final assets = start(withDirectory: false);
    expect(await assets.text('translations/en.json'), '{"hi":"Hi"}');
    expect(() => assets.file('translations/en.json'), throwsUnsupportedError);
  });

  test('patterns', () {
    expect(matchesPattern('translations/**', 'translations/en.json'), isTrue);
    expect(matchesPattern('translations/**', 'translations/de/app.json'), isTrue);
    expect(matchesPattern('translations/*.json', 'translations/de/app.json'), isFalse);
    expect(matchesPattern('**/*.json', 'a/b/c.json'), isTrue);
    expect(matchesPattern('**/*.json', 'c.json'), isTrue);
    expect(matchesPattern('pages/welcome.html', 'pages/welcome.html'), isTrue);
    expect(matchesPattern('pages/*.html', 'pages/welcome.htm'), isFalse);
  });
}
