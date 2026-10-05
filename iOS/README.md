# Skylights for iOS

A native iOS app that streams checksummed TMDB row chunks into Core Spotlight and applies deltas with a small resumable sync journal. Spotlight items carry the poster path and TV season count alongside searchable metadata. Selecting a result opens the matching `popfeed.social/movie/...` or `popfeed.social/tv_show/...` link, which iOS can route to the Popfeed app through Universal Links.

## Build

```sh
cd ios
xcodegen generate
open Skylights.xcodeproj
```

Choose an iOS Simulator or a signed iPhone and run the `Skylights` scheme. The app uses the public rolling release at `https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json`.

## Indexing limits and diagnostics

The app streams every row in the published catalogue; Core Spotlight controls storage, ranking, eviction, and when submitted items become visible. A successful submission means Core Spotlight accepted the operation; the app cannot inspect Apple's private index or guarantee every result appears in search.

The app keeps only a compact sync journal in preferences: the base hash, applied delta hashes, and the in-progress asset/chunk. It streams each independently checksummed chunk directly to Core Spotlight and advances the checkpoint after accepted operations. A changed base clears the app's Spotlight domain and streams the new base followed by its deltas. Poster paths and season counts are indexed as item keywords, so result details do not require a local catalog copy.

Posters are requested on demand when a result or detail page is shown; indexing the catalogue does not download covers. Search rows fetch a 180×180 blurred placeholder from `skylights-posters.watware.workers.dev` alongside the regular TMDB `w185` image. Detail pages request the Worker’s 180×270 blur alongside the full TMDB `w500` poster. The UI uses whichever blur arrives first and fades in the sharp image when it is ready. Worker responses are versioned and cached at the edge and in R2; the app uses normal HTTP caching and logs the Worker cache layer and fetch failures.

The app targets iOS 26 and starts a manually requested index run with `BGContinuedProcessingTask`. This continues after the app is backgrounded and reports progress through the system's Live Activity, including a cancel action. Runs checkpoint after each accepted stream chunk and can resume after interruption. Daily delta checks still use best-effort `BGAppRefreshTask` and `BGProcessingTask`; iOS may defer or skip those scheduled runs. Background runs reuse the journal and skip an unchanged base. A new base requires a foreground full rebuild. The app logs scheduling, HTTP responses, stream checksums, applied row counts, poster successes/failures, and batch errors. Logs go to unified logging under subsystem `com.tinycast.tmdbspotlight` / category `indexing` and to `Documents/tmdb-spotlight.log`; the app screen shows the latest 80 lines. On a connected device, use Console.app and filter by that subsystem to capture system-side Core Spotlight messages.

The Tinycast search index uses `TCIDX001` v6 rows, which include TV season counts. The release publishes separate row-operation streams for Spotlight, with a checksum on each chunk and a whole-asset hash in the manifest. A format-version change forces a base rebuild before deltas resume.
