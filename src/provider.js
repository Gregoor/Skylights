// The Tinycast root-search provider for TMDB movies and TV shows. Bundled to a single self-contained
// file that AppCore loads into a resident JavaScriptCore session.
//
// The index is NOT committed — it is rebuilt every day, so it ships as a GitHub Release asset beside a
// small manifest and per-day deltas. The manifest is fetched every launch and an index file only when
// its recorded hash changed, so a launch costs one small request and a day's update only that day's
// delta. The store (every record, ~140 MB compressed) ships as a third asset for base rebuilds.
//
// A provider's API surface is restricted to `rootSearch.*` + `open`, but the Node builtins are
// provided to every bundle by design — so the index is downloaded with curl through the process shim.
// That streams straight to disk, which the fetch path cannot: its polyfill is refused by the provider
// bridge, and a bare `fetch` only works where JavaScriptCore supplies a native one, buffering the
// whole body in memory. That, plus the resident-session runtime, makes this Tinycast-only: it is not a
// Raycast extension and must stay out of the Raycast store and any registry catalog.
//
// `@tinycast/api` exposes only `registerRootSearchProvider` and `open`, so `environment.supportPath` is
// out of reach and the host hands the cache directory over in the environment instead — already scoped
// by bundle id, so a Dev build's index never collides with an installed copy's. A re-downloadable,
// hash-verified artifact belongs in Caches rather than Application Support, and the host decides that;
// this file only has to be told where it is.
//
// The default export must stay "alive" (return a never-settling promise) so the resident session keeps
// the runtime mounted across keystrokes — see RootSearchProviderHost.

import { registerRootSearchProvider, open } from "@tinycast/api";
import { download, gunzip } from "./transfer.mjs";
import { createProviderCore, activationURL } from "./provider-core.mjs";

const MANIFEST_URL =
  "https://github.com/Gregoor/tinycast-tmdb/releases/latest/download/manifest.json";

const CACHE_DIR = process.env.TINYCAST_PROVIDER_CACHE;
if (!CACHE_DIR) {
  throw new Error("TINYCAST_PROVIDER_CACHE is unset — the host must say where the index belongs");
}

export default function command() {
  const fs = require("fs");
  const core = createProviderCore({
    manifestURL: MANIFEST_URL, cacheDir: CACHE_DIR, fs, download, gunzip, log: console.log,
  });

  registerRootSearchProvider({
    id: "movies",
    // A title that is both a film and an article — "Dune", "Severance" — matches both providers
    // equally, and each candidate `score` is relative to its own provider's matcher, so neither can
    // say which one was meant. This is what compares them across providers: where the two tie, the
    // movie is the answer and the wiki's article about it is the fallback, so the movie provider
    // outranks the encyclopedia (which declares the lower one below).
    precedence: 2,
    search: (query, { limit }) => core.search(query, limit),
    async perform(resultId) {
      const url = activationURL(resultId);
      if (url) await open(url, "Safari");
    },
  });

  // Keep the resident session mounted: never settle.
  return new Promise(() => {});
}