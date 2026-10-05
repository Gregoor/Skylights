# tinycast-tmdb

A Tinycast **root-search provider** for TMDB movies **and TV shows**, backed by an
extension-owned index that is updated daily.

Tinycast's launcher never holds the million-row corpus. This provider keeps its own compact binary
index, searches it locally in JavaScriptCore, and hands the launcher ~10 candidates per query.

> **Tinycast-only.** This is not a Raycast extension. It depends on Tinycast's root-search provider
> runtime, on the reduced `@tinycast/api` module that runtime hands a provider, and on the process
> shim for its downloads. It must not be listed in the Raycast store or any registry catalog.

## Repository layout

- Root `Scripts/`, `src/`, `data/`, and `build/` hold the CI index pipeline and its inputs/outputs.
- `tinycast/` holds Tinycast provider entry points, runtime glue, assets, and provider tests.
- `ios/` holds the Skylights Xcode project directly, with no extra app-name directory.

## Published release layout

The binary index is generated from the metadata store and ships on a rolling `latest` GitHub Release:

```
manifest.json            version + each asset's name, bytes and sha256
tmdb.index               the base index
delta-2026-09-23.index   one small index per day (new + changed records)
store.ndjson.gz          the metadata store, so a lost Actions cache needs no re-backfill
movies.provider.js       the built provider (source lives here in git)
wikipedia-<lang>.index   one index per wiki, each with its own manifest
wikipedia.provider.js    the built provider (source lives here in git)
```

`tinycast/assets/wikipedia.png` is Wikipedia's own mark, from Wikimedia Commons (CC BY-SA), drawn as the icon of
the rows the Wikipedia provider contributes. `Scripts/build-provider.mjs` copies it beside the bundle,
because the provider's own directory is all the host will resolve a candidate's icon against.

The client checks the manifest when its cache is older than six hours, and downloads an index file only
when the recorded hash differs from what is on disk. So a launch inside that window costs no request at
all, a check costs one small request, and a day's update costs only that day's delta.

## How a day's update runs

```
TMDB daily ID export (files.tmdb.org)         ~08:00 UTC
        │
        ▼
Scripts/fetch-exports.mjs                     movies + TV ids → data/id-export.ndjson
        │
        ▼
Scripts/daily-update.mjs                      1. new ids            → fetch metadata
        │                                     2. original-title edits→ free, from the export
        │                                     3. rolling re-fetch   → N stalest records
        ▼
data/records.ndjson                           the canonical store (append-only, last-wins per key)
        │
        ├──▶ Scripts/build-delta.mjs           → build/delta-<date>.index  (daily)
        └──▶ Scripts/build-index.mjs           → build/tmdb.index          (weekly base rebuild)
        │
        ▼
Scripts/publish.mjs                           rolling `latest` release + manifest
```

Popularity drift is deliberately not an update: the index stores it, but scoring never reads it, so
emitting it would churn the deltas for nothing.

## What the index covers

The store backup ships with every unique record from its snapshot; the index is what a client downloads
and holds resident. It keeps records matching this rule (`Scripts/band.mjs`):

```
at least 5 TMDB votes, or a Rotten Tomatoes score, or a Metacritic score, or an IMDb score
```

In the October 3, 2026 CI build, 1,485,581 live records matched the current TMDB ID export; this rule
kept 567,877. The resulting base index is 78.1 MB (74.5 MiB). Records outside the rule stay in the
store and can return to the index if a later update adds enough votes or a score.
The Daily index workflow publishes this base; both the Tinycast provider and TMDB Spotlight app read
the same rolling release manifest and delta chain.

## Languages and the entity map

The Wikipedia provider serves three wikis, and the same subject is very often spelled differently in
each: `New York City` / `Nueva York`, `Deaths in 2026` / `Nekrolog 2026`, `Mutiny on the Bounty (1962
film)` / `Meuterei auf der Bounty (1962)`. A title cannot tell those apart, so one row becomes three,
and a query that matched the German article never offers the English one.

`Scripts/fetch-wiki-groups.mjs` resolves each wiki's head to a Wikidata item and matches that item's
other-language articles back to rows **this repo ships**, writing one `wikipedia-<lang>.groups` per
language: a sparse table of (row → entity) and (entity → row), both sorted and binary searched. The
provider merges on the entity where it has one and on the title where it does not, so the unmapped tail
degrades to exactly the behaviour it had before.

Measured on the top 3,000 English articles by views: 94.8% resolve to an item, 2,487 groups of two or
more rows form, and **917 of them (37%) are differently named** — the merges a title alone cannot make.
Only the head is mapped, because the work is bounded by requests to a shared public endpoint rather
than by data: one 400-article chunk per request, so a 50k head across three languages is 375 requests.

### The wiki band

Each wiki's index is byte-budgeted too — a hundred megabytes, which lands around a million articles, one
index per language. What counts as an article is namespace 0, since everything else is talk pages, users,
templates and files; the one exception is Spanish `Anexo:` ("Appendix"), where that wiki keeps the pages
English and German write as "List of …" in the main namespace — measured at 2.35% and 1.70% of their
readership, so excluding it would drop a class of page the other bands carry.

`Special:` / `Especial:` is namespace −1 and is deliberately not filtered, which is why `Especial:Buscar`
appears among the Spanish band's rows.

## Ratings

Three sources, stored per row as three bytes in the index (256 = absent):

| source | how | coverage |
|---|---|---|
| IMDb | their bulk `title.ratings.tsv.gz`, 8.7 MB/day, no key, no rate limit | ~100% of records with an IMDb id |
| Rotten Tomatoes | OMDb, one title at a time | ~5% of films, ~0% of series |
| Metacritic | OMDb, then MDBList batch lookups by TMDB id | OMDb: ~4% of films, ~0% of series; MDBList batches up to 200 ids per read and checks its change feed, TV first |

OMDb's Metascore is movie-only — it returns `N/A` for series that Metacritic plainly scores — and its
RT/Metacritic data reaches only the prominent few thousand. `Scripts/fetch-ratings.mjs` spends its
quota on likely reviewed titles; `Scripts/fetch-mdblist-ratings.mjs` fills missing Metacritic scores
against TMDB ids in 200-item batches, TV first, within the MDBList daily budget. It also polls
MDBList's movie/show update feeds to prioritize titles whose ratings or metadata changed. IMDb
remains the broad fallback rating.

A row shows `rt` for both media types with `imdb` behind it as a fallback; any combination, in any
order, is configurable from a `config.json` in the provider's cache directory. Tinycast hands the bundle
that directory (its `TINYCAST_PROVIDER_CACHE`), scoped per channel and per bundle id so a Dev build never
shares an installed copy's index:

```
~/Library/Caches/<bundle id>/provider-cache/movies/config.json
```

```json
{ "ratings": { "movie": ["rt", "metacritic"], "tv": ["rt"], "fallback": ["imdb"] } }
```

An edit applies on the next palette open.

## Deltas and updates

A day's delta is **an index in the same format** — no binary patch, no LSM. It carries the records
that changed plus the **stable keys it supersedes** (`id * 2 + mediaType`). The client searches the
base and every delta, then:

- drops any base candidate whose key a newer delta supersedes — so an edited *title* stops matching
  even though the delta's new text would not have matched the query;
- dedupes by key, newest delta winning.

A record removed from the export is superseded with no replacement, which is how deletions fall out
of the same mechanism.

## Why this shape

- **The index is extension-owned.** ~1.5M rows never enter Tinycast's `AppIndex`; the provider
  searches locally and returns a bounded candidate set.
- **The provider orders its own rows, and says so.** Each candidate carries a `score` on 0…1 —
  `movieScore`'s tiers, normalized to the result set's best row — which Tinycast folds into its own
  ranking. It is provider-relative by design and never compared with another provider's scale.
- **A query never waits for the mount.** The provider mounts in the background as its session starts —
  which is when the palette opens — and a query that finds nothing mounted yet answers nothing rather
  than blocking. A fresh install or a republish therefore pays its download and gunzip in the
  background, never inside a keystroke.
- **The store is durable**, so the multi-hour backfill and each daily delta restart without
  re-fetching what is present (`data/records.ndjson` is the checkpoint).
- **The index ships as a Release asset.** Release assets have no expiry (unlike Actions artifacts,
  which default to 90 days), and each is capped at 2 GB.
- **The store is cached in Actions, but also published.** The Actions cache evicts after 7 idle days,
  so a cold cache restores `store.ndjson.gz` from the release instead of re-backfilling for hours.

## The provider's environment

A root-search provider is restricted at the **API** level, not the module level: its `@tinycast/api` is
only `{registerRootSearchProvider, open}`, but the Node builtins are provided to every bundle by
design.

| Available | Not available |
|---|---|
| `fs`, `proc`, `crypto`, `zlib`, `os` (Node builtins) | `environment` (so the cache path is derived from `os.homedir()`) |
| `registerRootSearchProvider`, `open` | the rest of the API surface — storage, clipboard, `fetch` |

So the index is downloaded with **curl through the process shim**, streaming straight to disk. The
fetch path can't do that: the runtime's fetch polyfill is refused by the provider bridge, and a bare
`fetch` only works where JavaScriptCore supplies a native one — which buffers the whole body in
memory, the last thing a large index download needs.

The transport is isolated in one `download(url, path)` function, so swapping it (say, for a future
host-side sync) touches nothing in the sync, format or merge logic.

## The index format (`src/db/index-format.mjs`)

One little-endian binary file (v6): a 128-byte header, per-row records (42 B), a sorted term table
(offsets + packed UTF-8 + postings ranges), a flat postings array, title/original/poster pools, and a
superseded-keys section (empty for a base). A row carries tmdbID, title/original offsets, year, imdb
id, popularity, vote count, poster offset, media type (0 movie, 1 TV), and TV season count. The loader keeps only the
inverted index in memory (~30 MB); the pools stay on disk and are paged per query.

## Running it

```sh
npm install

# Local secrets (gitignored): a v4 read token or a v3 key.
printf 'TMDB_READ_TOKEN=...\n' > .env

# First seed — hours, resumable: re-run until `to fetch 0`.
npm run fetch-exports
npm run backfill

# Build
npm run build-index      # the base
npm run build-delta      # or a delta, given a changed store
npm run build-provider

# The whole daily cycle:
npm run update
```

Wikipedia is its own chain — a pageview sample, one index per wiki, then the cross-language map:

```sh
node Scripts/fetch-wikipedia-views.mjs --date=YYYY-MM-DD --min-views=1 --keep=1000000
node Scripts/fetch-wikipedia.mjs --min-views=1
for lang in en de es; do node Scripts/build-index-wikipedia.mjs $lang --budget-mb=100; done

# Wikidata ids, kept per title: the first pass is thousands of requests, every run after it is the new
# articles. A title without one keeps a hash of itself as its id.
node --max-old-space-size=8192 Scripts/fetch-wiki-keys.mjs --delay 500

# A base: one index per wiki, plus the entity map. `--write` also refreshes the manifests, because a
# manifest records the map's bytes and a stale one fails the client's check.
for lang in en de es; do node Scripts/build-index-wikipedia.mjs $lang --budget-mb=100; done
node --max-old-space-size=8192 Scripts/fetch-wiki-groups.mjs --head 50000 --from en,de,es --write

# Or a delta, against the marker the last publish moved:
node Scripts/build-wikipedia-delta.mjs en --mark

# Publish to the same rolling `latest` release the movie index uses. One release, not two:
# `releases/latest/download/...` resolves to the most recent, so a second would take the URL the first
# one's clients depend on. `--base` republishes the whole index and restarts the delta chain.
node Scripts/publish-wikipedia.mjs
```

`.github/workflows/wikipedia.yml` runs that chain daily: a delta most days, a base on Sundays or when
its cache is cold. Everything below is what makes the delta small enough to be worth having.

**The store is incremental.** `popularity` is a decayed score rather than a day's reading (see
`src/wikipedia/popularity.mjs`), so an article's standing is a rate: a rebuild folds the day in rather
than replacing it, and a skipped run decays by the time it missed. **The identity is stable.** `id` is a
hash of the language and title, so a rebuild can say what changed instead of renumbering every row — the
first thing this pipeline could not do.

**And the index ships a level, not the score.** The band is chosen on the exact standing, then what
ships is its octave. That split is the whole point: the exact score moves every day for nearly every
row, so shipping it would make every rebuild a full republish, while a level only moves when the rate
does. Measured over the 2026-09-24 sample and a resampled day after it: rows whose shipped value changed
fell from 83–96% to a few percent, and the band itself stopped reshuffling.

`TMDB_API_KEY` (v3) also works in place of `TMDB_READ_TOKEN` (v4 bearer).

## Daily automation

`.github/workflows/daily.yml` runs every day at 09:00 UTC and Sundays for a base rebuild: restore the
store (cache, else the release asset), download the export, run the incremental update, build a delta
or the base, publish, and save the store. It needs one repository secret, `TMDB_READ_TOKEN`.

## Verifying

```sh
npm test                                   # smoke, delta/update merge, sync, provider glue
npm run test:rank                          # ranking + no-miss against a real index
node test/perf.mjs build/tmdb.index        # warm p50/p95/p99
```
