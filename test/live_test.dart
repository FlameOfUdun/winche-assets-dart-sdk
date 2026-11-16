@Tags(['live'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_assets/winche_assets.dart';
import 'package:winche_core/winche_core.dart';

/// Against a server (or `winche emulators start` with an assets folder) whose channel has `translations/*.json`
/// readable by anyone: `WINCHE_ASSETS=http://localhost:9090 dart test --tags live` (WINCHE_ASSETS_CHANNEL, default
/// production).
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
}
