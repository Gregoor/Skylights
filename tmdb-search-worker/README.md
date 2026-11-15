# TMDB search Worker

Public title search backed by Cloudflare D1 and SQLite FTS5. It imports the full metadata store from
the rolling Skylights release; it does not apply the smaller app-search inclusion band.

## Provision and deploy

The full catalog plus FTS needs a D1 database large enough for the imported rows and its text index.
Cloudflare Free limits a database to 500 MB, so use a Workers Paid account for the full dataset.

```sh
npx wrangler@4 d1 create skylights-tmdb-search
```

Copy the returned database ID into `database_id` in `wrangler.jsonc`, then apply the schema and deploy:

```sh
npx wrangler@4 d1 migrations apply skylights-tmdb-search --remote
npx wrangler@4 deploy
```

Authenticate first with `npx wrangler@4 login`, or set `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` in the environment. The token needs D1 edit and Workers edit permissions.

## Seed the catalog

Fetch the current source snapshot from the rolling GitHub release and sync it to D1:

```sh
mkdir -p /tmp/tmdb-store
gh release download latest --repo Gregoor/Skylights -p store.ndjson.gz -D /tmp/tmdb-store
node import.mjs --source=/tmp/tmdb-store/store.ndjson.gz
```

The importer collapses the append-only NDJSON store to the latest row per movie/TV ID, then writes
only records newer than the checkpoint in `sync_state`. It is safe to rerun after an interrupted
upload. `backfill-ratings.mjs` imports the rating history from the same snapshot after migration
0002; it updates existing rows by their primary key and leaves the catalog metadata and FTS rows
alone.

## Scheduled refresh

The Worker's Cron handler refreshes the catalog from TMDB's daily movie and TV ID exports, fetches
new and changed title metadata, refreshes the 5,000 stalest titles, applies IMDb's daily ratings
file, and enriches titles through OMDb and MDBList. The ID export is staged in D1 so new-title
metadata can be fetched in small, resumable batches across Cron invocations. Progress, daily API
budgets, and an execution lock are stored in D1.

Set `TMDB_READ_TOKEN` and `OMDB_API_KEY` as Worker secrets before deploying. `MDBLIST_API_KEY`
is optional; that source is skipped when absent. The Worker Cron is configured in `wrangler.jsonc`
and now owns D1 ingestion. The GitHub Daily Index workflow remains to publish the downloadable
catalog used by Skylights Spotlight until that client moves; its enrichment work temporarily overlaps
with the Worker. The separate GitHub workflow that imported the catalog into D1 has been removed.

## Search API

```text
GET /search?q=matrix&limit=20&type=movie
GET /healthz
```

`q` supports prefix matching across the current title, original title, and release year. Multiword
queries require all terms. Results order text-match tiers first, so an exact title match always beats a
weaker match. Within each tier, `relevance_score` blends the candidate's BM25 percentile (85%) with
rating quality (15%): Rotten Tomatoes for movies and Metacritic for shows. Missing ratings are neutral.
Year match, recent release and logarithmic TMDB-vote bonuses break ties; `score` remains the raw FTS5
BM25 value. The FTS5 index retrieves candidates; stored folded titles let SQL score accent-insensitive
matches without normalizing title strings during each query. No extra B-tree indexes are used for
ranking-only fields.
`limit` is capped at 50; `type` can be `movie` or `tv`. Search responses are cached at Cloudflare's
edge for 24 hours, with stale-while-revalidate for one hour. After ingestion changes search-visible
D1 data, the Worker purges its full cache; timestamp-only refreshes do not purge it. The endpoint is
public on the Worker’s `workers.dev` hostname and allows browser CORS requests.
