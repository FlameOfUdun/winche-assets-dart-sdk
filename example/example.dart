import 'package:winche_assets/winche_assets.dart';
import 'package:winche_core/winche_core.dart';

Future<void> main() async {
  Winche.initializeApp(options: WincheOptions(baseUrl: Uri.parse('http://localhost:9090')));   // winche emulators start

  final assets = WincheAssets.instance
    ..settings = const WincheAssetsSettings(channel: 'production', prefetch: ['translations/**']);
  final release = await assets.sync();
  print('Release #${release.number}: ${release.files.length} files');

  final strings = await assets.json('translations/en.json') as Map<String, dynamic>;
  print(strings['hello']);
}
