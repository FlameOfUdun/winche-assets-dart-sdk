# winche_assets

An app's versioned content from **Winche Assets**: translations, HTML pages, images and videos, published from the
CLI as numbered releases and followed through a channel (`production`, `beta`, one per app version). Everything the
app reads is kept on the device, so it works offline.

```dart
final assets = WincheAssets.instance
  ..settings = const WincheAssetsSettings(
    channel: 'production',
    prefetch: ['translations/**', 'pages/*.html'],   // downloaded by sync(), so they're there from the start
  );

await assets.sync();                                      // the channel's release (only when it changed)
final de = await assets.json('translations/de.json');     // from the device: offline too
final page = await assets.text('pages/welcome.html');
final video = await assets.file('videos/intro.mp4');      // downloaded on first use, then kept: video.localPath
assets.releases.listen((r) => print('Release #${r.number}'));
```

## Install

```yaml
dependencies:
  winche_assets: ^0.1.0
```

It works with any `winche_core` app; with Flutter, start it with `WincheFlutter.initializeApp` so assets are kept in
the app's folder (on the web they're kept in memory, and `file()` isn't available).

## How it works

- **`sync()`** asks for the channel's listing with the release it has; the server answers 304 when nothing changed.
  Offline it throws `unavailable` and what was kept from the last sync stays in use. Call it at start and when the
  app comes back to the foreground; a new release shows on `releases`.
- **Reads** (`bytes`, `text`, `json`, `file`) use the release synced last. A file not on the device yet is downloaded
  once (however many ask at the same time), from the server's signed link without the user's token, and checked
  against its SHA-256 before it's kept. `isKept(path)` says whether a read works offline.
- **What you may see** is the server's rules': the listing has only the files you may list, and reading one you may
  not is `permissionDenied`. It's kept per user: signing in or out switches to that user's listing.
- **What's kept**: each content once by hash (a file that didn't change between releases isn't downloaded again),
  up to `maxCacheBytes` (512 MB by default). Past it, contents no longer released go first, then the least recently
  used; prefetched files of the current release are always kept. `clearCache()` forgets everything.

## Publishing

```sh
winche assets init                       # an assets/ folder and assets.rules
winche rules deploy --only assets        # who may read which paths
winche assets deploy -m "German"         # a new release; the channel points at it
```

The emulators (`winche emulators start`) publish the assets folder on every save: point the app at them to try a change.

## License

MIT
