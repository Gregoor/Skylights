# TMDB Spotlight for iOS

A native iOS app that downloads the rolling TMDB release, validates and expands its v5 index, applies delta supersession, then submits a bounded subset to Core Spotlight.

## Build

```sh
cd iOS/TMDBSpotlight
xcodegen generate
open TMDBSpotlight.xcodeproj
```

Choose an iOS Simulator or a signed iPhone and run the `TMDBSpotlight` scheme. The app uses the public rolling release at `https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json`.

## Indexing limits and diagnostics

Core Spotlight controls storage, ranking, eviction, and when submitted items become visible. The app defaults to 30,000 titles, ranked by vote count then TMDB popularity, and submits 250 items per call. The cap is adjustable up to 150,000. These are app-side guardrails, not guarantees about Apple's private Spotlight capacity. A successful submission means Core Spotlight accepted the call; the app cannot inspect the private index or guarantee every result appears in search.

The app logs each HTTP response, manifest version, gzip byte count, SHA-256 check, parsed row and delta counts, selected cap, every Core Spotlight batch duration, and any batch error. Logs go to unified logging under subsystem `com.tinycast.tmdbspotlight` / category `indexing` and to `Documents/tmdb-spotlight.log`; the app screen shows the latest 80 lines. On a connected device, use Console.app and filter by that subsystem to capture system-side Core Spotlight messages.

The dataset's binary format is decoded directly from the repository's `TCIDX001` v5 format; a version or integrity mismatch fails visibly. Missing/unpublished deltas are logged and skipped, matching the existing Tinycast client's partial-release handling.
