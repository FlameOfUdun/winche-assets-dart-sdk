@Tags(['live'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_assets/winche_assets.dart';
import 'package:winche_core/winche_core.dart';

/// Against a server (or `winche emulators start` with an assets folder) whose channel has `translations/*.json`
/// readable by anyone: `WINCHE_ASSETS=http://localhost:9090 dart test --tags live` (WINCHE_ASSETS_CHANNEL, default
/// production). WINCHE_ASSETS_CDN_FILE names a file of the channel kept on a CDN, to download it from there.
void main() {
  final base = Platform.environment['WINCHE_ASSETS'];
  final channel = Platform.environment['WINCHE_ASSETS_CHANNEL'] ?? 'production';
  final skip = base == null ? 'set WINCHE_ASSETS=<server url> with assets published' : false;

  test('syncs the channel, prefetches translations and reads them offline after', () async {
    final dir = Directory.systemTemp.createTempSync('winche-assets-live-');
    final app = Winche.initializeApp(name: 'live', options: WincheOptions(baseUrl: Uri.parse(base!), directoryResolver: () async => dir.path));
    final assets = WincheAssets.instanceFor(app)..settings = WincheAssetsSettings(channel: channel, prefetch: const ['translations/**']);
    final release = await assets.sync();
    final translations = await assets.paths('translations/*.json');
    expect(translations, isNotEmpty);
    for (final path in translations) {
      expect(await assets.isKept(path), isTrue, reason: path);
      expect(await assets.json(path), isA<Map<String, dynamic>>());
    }
    final again = await assets.sync();   // a 304: the same release
    expect(again.number, release.number);
    await Winche.deinitializeAll();
    dir.deleteSync(recursive: true);
  }, skip: skip);

  final cdnFile = Platform.environment['WINCHE_ASSETS_CDN_FILE'];
  test('downloads a file kept on a CDN through the link the server gives, checked against its hash', () async {
    final dir = Directory.systemTemp.createTempSync('winche-assets-live-');
    final app = Winche.initializeApp(name: 'live-cdn', options: WincheOptions(baseUrl: Uri.parse(base!), directoryResolver: () async => dir.path));
    final assets = WincheAssets.instanceFor(app)..settings = WincheAssetsSettings(channel: channel);
    final release = await assets.sync();
    final entry = release[cdnFile!]!;
    expect(await assets.isKept(cdnFile), isFalse);
    final kept = await assets.file(cdnFile);
    expect(File(kept.localPath).lengthSync(), entry.size);
    expect(await assets.isKept(cdnFile), isTrue);
    await Winche.deinitializeAll();
    dir.deleteSync(recursive: true);
  }, skip: skip != false ? skip : cdnFile == null ? 'set WINCHE_ASSETS_CDN_FILE=<a path kept on a CDN>' : false, timeout: const Timeout(Duration(minutes: 5)));
}
