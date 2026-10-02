# Skylights Poster Service

A small Cloudflare Worker that creates a square, softly blurred poster on demand. It currently accepts TMDB posters only. Clients pass a source URL, which is checked against a fixed allowlist before the Worker fetches anything.

## Endpoint

```text
GET https://<worker-host>/v1/poster?url=<url-encoded-image-url>
```

For example, a TMDB `poster_path` of `/abc123.jpg` maps to the encoded source URL `https://image.tmdb.org/t/p/w185/abc123.jpg`. The default is a 180 × 180 JPEG; pass `size=portrait` for a 180 × 270 JPEG. Both are center-cropped, blur strength 15, quality 65.

Responses use a one-year immutable cache policy. Workers Caching is enabled in `wrangler.jsonc`, so Cloudflare checks its cache before invoking the Worker; a hit returns the thumbnail without running Worker code. On a cache miss, the Worker checks its regional edge cache, then the persistent R2 bucket, and on a cold miss fetches the fixed TMDB `w185` image, transforms it, and writes both caches asynchronously. `X-Poster-Cache` reports `EDGE-HIT`, `R2-HIT`, or `MISS` for requests that reach the Worker. Structured Worker logs include cache layer, transform duration, upstream failures, and cache-write failures.

The source URL is checked against an exact allowlist before fetching. Only HTTPS URLs from `image.tmdb.org` under `/t/p/w185/` are accepted today. The only transform choice is `size=square` or `size=portrait`; clients cannot choose arbitrary dimensions or blur strength. Adding Open Library later requires an explicit origin and path rule in `src/index.js`; clients still must not be allowed to fetch arbitrary URLs.

## Deploy

The repository workflow deploys this Worker when `poster-service/` changes are pushed to `main`. Add these repository secrets in GitHub Settings → Secrets and variables → Actions:

- `CLOUDFLARE_API_TOKEN`: a scoped Cloudflare API token with permission to edit Workers and manage the R2 bucket for this account.
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID.

Create the R2 bucket once, then the GitHub workflow handles future deployments. From this folder, run:

```sh
npx wrangler@latest login
npx wrangler@latest r2 bucket create skylights-poster-cache
npx wrangler@latest deploy
```

For local development:

```sh
npx wrangler@latest dev
```

Cloudflare may prompt to enable the Images binding or R2 access on first use. The deployed Worker URL will be shown by Wrangler. Set that URL as the iOS app's poster-thumbnail service base URL before routing app requests through it.

## Operations and cost

Only requested posters are transformed. The first request can be slower than loading the original TMDB poster because it has to fetch and transform it; subsequent requests are served from Cloudflare cache without running the Worker, or fall back to the Worker's edge/R2 cache layers. R2 keeps the transformed copy persistently, while Cloudflare's edge cache avoids an R2 lookup in regions where the poster was recently requested. An unused poster incurs no transform or storage cost.

This service does not need a TMDB API key: it reads only public poster files from the fixed TMDB image CDN.
