/// An app's versioned content from Winche Assets: translations, pages, images and videos, published as releases
/// and followed through a channel, kept on the device so they work offline.
///
/// ```dart
/// final assets = WincheAssets.instance
///   ..settings = const WincheAssetsSettings(channel: 'production', prefetch: ['translations/**']);
/// await assets.sync();
/// final strings = await assets.json('translations/de.json') as Map<String, dynamic>;
/// final intro = await assets.file('videos/intro.mp4');
/// ```
library;

export 'src/winche_assets.dart';
