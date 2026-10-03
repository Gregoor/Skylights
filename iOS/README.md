# TMDB Spotlight for iOS

A native iOS app that downloads the rolling TMDB release, validates and expands its v5 index, applies delta supersession, and submits a bounded subset to Core Spotlight. It reads poster paths from the same index rows the Tinycast extension uses. Selecting a Spotlight result opens the matching `popfeed.social/movie/...` or `popfeed.social/tv_show/...` link, which iOS can route to the Popfeed app through Universal Links.

## Build

```sh
cd iOS/TMDBSpotlight
xcodegen generate
open TMDBSpotlight.xcodeproj
```

Choose an iOS Simulator or a signed iPhone and run the `TMDBSpotlight` scheme. The app uses the public rolling release at `https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json`.

## Indexing limits and diagnostics

Core Spotlight controls storage, ranking, eviction, and when submitted items become visible. The app defaults to indexing all titles in the published TMDB index, ranked by vote count then TMDB popularity, and submits 250 items per call. You can turn off full indexing and set a cap from 1,000 to 150,000 titles. These are app-side guardrails, not guarantees about Apple's private Spotlight capacity. A successful submission means Core Spotlight accepted the call; the app cannot inspect the private index or guarantee every result appears in search.

The app persists a compact binary-plist snapshot in Application Support: merged rows, the base SHA-256, applied delta hashes, and the set of Spotlight identifiers. Daily/manual refreshes fetch the manifest and only deltas absent from that snapshot. If GitHub publishes a new base, a foreground sync rebuilds from that base and its deltas; a background run logs that a foreground rebuild is needed. Rebuilds resume from their last accepted 250-item batch after interruption.

Poster images are fetched from TMDB's `w185` image endpoint, cached locally, and attached with Core Spotlight's local thumbnail URL. The full index downloads every available poster. Downloads are bounded to six concurrent requests; missing/failed posters are logged while title indexing continues. The cache is opportunistic and may be evicted by iOS, so thumbnails are fetched again when those items are next updated.

The app targets iOS 26 and starts a manually requested index run with `BGContinuedProcessingTask`. This continues after the app is backgrounded and reports progress through the system's Live Activity, including a cancel action. Runs checkpoint at accepted batches and can resume after interruption. Daily delta checks still use best-effort `BGAppRefreshTask` and `BGProcessingTask`; iOS may defer or skip those scheduled runs. Background runs reuse the saved row snapshot and do not re-download an unchanged base. A new base is deferred to a user-started full rebuild. The app logs scheduling, HTTP responses, gzip byte counts, SHA-256 checks, parsed row/delta counts, incremental plans, poster successes/failures, every Core Spotlight batch duration, and any batch error. Logs go to unified logging under subsystem `com.tinycast.tmdbspotlight` / category `indexing` and to `Documents/tmdb-spotlight.log`; the app screen shows the latest 80 lines. On a connected device, use Console.app and filter by that subsystem to capture system-side Core Spotlight messages.

The dataset's binary format is decoded directly from the repository's `TCIDX001` v5 format; a version or integrity mismatch fails visibly. Missing/unpublished deltas are logged and skipped, matching the existing Tinycast client's partial-release handling.
