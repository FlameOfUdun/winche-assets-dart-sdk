# CHANGELOG

## 0.1.0

* **`WincheAssets`**: an app's versioned content from Winche Assets (`/assets/v1`). `sync()` takes the release a
  channel points at (a 304 when it hasn't changed) and downloads the `prefetch` paths; `bytes`, `text`, `json` and
  `file` read from the device, downloading on first use. Everything is kept for offline use (contents once by hash,
  listings per user), within `maxCacheBytes`.
* Downloads come through the server's signed links without the user's token, and are checked against their hash.
