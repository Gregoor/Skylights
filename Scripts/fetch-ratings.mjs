#!/usr/bin/env node
// Enriches the store with ratings from OMDb: Rotten Tomatoes and Metacritic scores plus IMDb's own.
// One OMDb request yields all three, so all three are kept.
//
// OMDb's free tier is 1,000 requests/day, and RT/Metacritic scores only exist for titles those sites
// reviewed — coverage on a random draw from this corpus is ~4%, but 100% across the most-voted few
// thousand. So this walks the store by vote count, descending, and stops at its request budget.
//
// It is resumable and quota-aware: ratings land on the record itself (append-only, last-wins), so a
// re-run skips what is already fresh and continues where it left off.
//
//   OMDB_API_KEY=... node Scripts/fetch-ratings.mjs [--top=5000] [--max-requests=1000]
//                                        [--refresh-days=30] [--requests-per-second=5] [--out data]

import { readStore, appendRecord } from "./store.mjs";
import { inBand } from "./band.mjs";
import { readResponse } from "../src/omdb.mjs";

const API = "https://www.omdbapi.com/";

const apiKey = process.env.OMDB_API_KEY;
if (!apiKey) {
  console.error("set OMDB_API_KEY in the environment");
  process.exit(2);
}

// Detached runs outlive whatever was reading their log; a write to a closed pipe must not kill them.
for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});

function argValue(flag) {
  const arg = process.argv.find((a) => a.startsWith(flag));
  return arg ? arg.slice(flag.length) : undefined;
}

const outDir = argValue("--out=") ?? "data";
const top = Number(argValue("--top=") ?? 5000);
const maxRequests = Number(argValue("--max-requests=") ?? 1000);
const refreshDays = Number(argValue("--refresh-days=") ?? 30);
// Target titles in the published index plus recent releases that might earn their first RT/Metacritic
// score. A score makes a low-vote title indexable, so keep checking recent titles even before they
// qualify; old titles with no score are unlikely to gain one and do not spend the limited quota.
const rps = Number(argValue("--requests-per-second=") ?? 5);
const DAY = 24 * 60 * 60 * 1000;
const now = Date.now();
const thisYear = new Date().getFullYear();

// A score only really moves while a title is new — reviews keep arriving for a couple of years, then
// it is effectively frozen. So recent releases go stale sooner, and the budget lands where change is.
const staleAfter = (rec) => ((rec.year ?? 0) >= thisYear - 2 ? Math.max(1, refreshDays / 4) : refreshDays);

// A score can only change if there is one, or if the title is new enough that a first one may still
// arrive. OMDb has never scored most of this corpus and never will — a 2004 film it passed on is not
// going to acquire a Metacritic — so re-asking every enriched record monthly spends the entire quota
// re-discovering nothing. Measured: re-asking all 563,782 enriched records needs ~21k requests/day;
// asking only what can change needs ~5k.
const canChange = (rec) =>
  rec.rtScore != null || rec.metacriticScore != null || (rec.year ?? 0) >= thisYear - 1;
const isStale = (rec) =>
  !rec.ratingsAt || (canChange(rec) && rec.ratingsAt < now - staleAfter(rec) * DAY);
const canQualifyWithRating = (rec) => inBand(rec) || (rec.year ?? 0) >= thisYear - 1;

const store = readStore(outDir);

// Only records OMDb can be asked about by id.
//
// Ordering serves two runs in one: records with no rating come first, most-voted first (the backfill),
// then rated ones oldest-first (the refresh). Sorting the whole queue by votes would mean a bounded
// budget re-checked the same popular titles for ever and never reached the tail.
const queue = [...store.entries()]
  .filter(([, rec]) => (rec.imdbId ?? "").trim())
  .filter(([, rec]) => canQualifyWithRating(rec))
  .filter(([, rec]) => isStale(rec))
  .sort((a, b) => {
    const aRated = a[1].ratingsAt ?? 0;
    const bRated = b[1].ratingsAt ?? 0;
    if ((aRated === 0) !== (bRated === 0)) return aRated === 0 ? -1 : 1;
    if (aRated === 0) return (b[1].voteCount ?? 0) - (a[1].voteCount ?? 0);
    return aRated - bRated;
  })
  .slice(0, top);

const outsideBand = [...store.values()].filter((r) => !inBand(r)).length;
console.log(`store ${store.size}; ${outsideBand} outside the index rule; candidates ${queue.length}; budget ${maxRequests}`);
if (process.argv.includes("--dry-run")) {
  for (const [recordKey, rec] of queue.slice(0, 10)) {
    const state = rec.ratingsAt ? `rated ${Math.round((now - rec.ratingsAt) / DAY)}d ago` : "unrated";
    console.log(`  ${recordKey.padEnd(14)} votes ${String(rec.voteCount ?? 0).padStart(6)}  ${String(rec.year ?? "-").padStart(4)}  ${state}`);
  }
  console.log(`  ...${queue.length - 10} more`);
  process.exit(0);
}

/// "8.3" -> 83, "N/A"/absent -> null, so a score is one byte on disk.
const score100 = (value) => {
  const n = Number.parseFloat(String(value ?? "").replace("%", ""));
  return Number.isFinite(n) ? Math.max(0, Math.min(100, Math.round(n))) : null;
};
const imdb100 = (value) => {
  const n = Number.parseFloat(String(value ?? ""));
  return Number.isFinite(n) ? Math.max(0, Math.min(100, Math.round(n * 10))) : null;
};

let done = 0;
let withRt = 0;
let withMeta = 0;
let unknown = 0;
let errors = 0;
const started = Date.now();

for (const [recordKey, rec] of queue) {
  if (done >= maxRequests) {
    console.log(`stopping at the ${maxRequests}-request budget (${queue.length - done} left for next run)`);
    break;
  }
  // Token-bucket-ish spacing; OMDb documents a daily quota, not a per-second one.
  const wait = (done + 1) * (1000 / rps) - (Date.now() - started);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));

  let payload;
  try {
    const response = await fetch(`${API}?apikey=${apiKey}&i=${encodeURIComponent(rec.imdbId.trim())}`);
    payload = readResponse(await response.text());
  } catch (error) {
    errors++;
    console.error(`  ${recordKey}: ${error.message}`);
    continue;
  }
  done++;

  if (payload?.Error) {
    // A bad key or an exhausted quota is fatal, not a per-title miss.
    if (/invalid api key|limit/i.test(payload.Error)) {
      console.error(`fatal: ${payload.Error} (after ${done} requests)`);
      process.exitCode = 1;
      break;
    }
    unknown++;
    continue;
  }

  const ratings = payload?.Ratings ?? [];
  const rt = score100(ratings.find((r) => /rotten tomatoes/i.test(r.Source))?.Value);
  const metacritic = score100(ratings.find((r) => /metacritic/i.test(r.Source))?.Value);
  const imdb = imdb100(payload?.imdbRating);
  if (rt !== null) withRt++;
  if (metacritic !== null) withMeta++;

  // Append-only last-wins: the record gains the ratings, and the index/delta machinery carries the
  // change like any other edit.
  // `fetchedAt` moves too: it is the marker `build-delta` reads to decide which records changed, so
  // without it a new score would only reach a client at the next base rebuild instead of that day.
  const stamp = Date.now();
  appendRecord(outDir, {
    ...rec, imdbRating: imdb, rtScore: rt, metacriticScore: metacritic,
    ratingsAt: stamp, fetchedAt: stamp,
  });

  if (done % 100 === 0) {
    console.log(`  ${done}/${Math.min(maxRequests, queue.length)} — rt ${withRt}, metacritic ${withMeta}, unknown ${unknown}, errors ${errors}`);
  }
}

const minutes = ((Date.now() - started) / 60000).toFixed(1);
console.log(`done: ${done} requests in ${minutes}m (rt ${withRt}, metacritic ${withMeta}, unknown ${unknown}, errors ${errors})`);
// One unreadable response is not a failed run, and failing it stops CI before it publishes — which is
// exactly what happened once. A systemic failure (a dead key, a blocked host, an outage) still has to
// fail loudly, so the threshold is a fraction of the run rather than a count.
if (errors > Math.max(10, done * 0.05)) process.exitCode = 1;
