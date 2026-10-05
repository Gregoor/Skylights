#!/usr/bin/env node
// Backfills Metacritic scores from MDBList for indexed TMDB movies and shows. OMDb's Metascore
// coverage is especially sparse for TV; MDBList returns ratings against our native TMDB ids.
//
// The store is append-only, so this resumes safely after a daily quota or interrupted run. A score
// already provided by OMDb is kept. MDBList misses are timestamped and only retried for recent titles.
//
//   MDBLIST_API_KEY=... node Scripts/fetch-mdblist-ratings.mjs [--max-requests=10000]
//     [--requests-per-second=3] [--refresh-days=30] [--out=data]

import { readStore, appendRecord } from "./store.mjs";
import { inBand } from "./band.mjs";

const API = "https://api.mdblist.com";
const apiKey = process.env.MDBLIST_API_KEY;
if (!apiKey) {
  console.error("set MDBLIST_API_KEY in the environment");
  process.exit(2);
}

for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});

function argValue(flag) {
  const arg = process.argv.find((a) => a.startsWith(flag));
  return arg ? arg.slice(flag.length) : undefined;
}

const outDir = argValue("--out=") ?? "data";
const maxRequests = Number(argValue("--max-requests=") ?? 10000);
// MDBList caps reads at 1,000 per fixed five-minute window. Three per second stays below that cap.
const rps = Number(argValue("--requests-per-second=") ?? 3);
const refreshDays = Number(argValue("--refresh-days=") ?? 30);
const now = Date.now();
const today = new Date(now);
const thisYear = today.getUTCFullYear();
const dayMs = 24 * 60 * 60 * 1000;

const store = readStore(outDir);
const isRecent = (rec) => (rec.year ?? 0) >= thisYear - 1;
const retryRecentMiss = (rec) => isRecent(rec) &&
  (rec.mdblistRatingsAt ?? 0) < now - refreshDays * dayMs;
const queue = [...store.entries()]
  .filter(([, rec]) => inBand(rec) || isRecent(rec))
  // Never overwrite an existing OMDb (or other upstream) score. Records tagged as MDBList may
  // refresh after the normal recent-title interval as critics add reviews.
  .filter(([, rec]) => rec.metacriticScore == null || rec.metacriticSource === "mdblist")
  .filter(([, rec]) => !rec.mdblistRatingsAt || retryRecentMiss(rec) ||
    (rec.metacriticSource === "mdblist" && retryRecentMiss(rec)))
  // Fill the TV gap first; within each media type, handle the most visible titles first.
  .sort((a, b) => {
    const tv = (b[1].mediaType === "tv") - (a[1].mediaType === "tv");
    const recent = Number(isRecent(b[1])) - Number(isRecent(a[1]));
    return tv || recent || (b[1].popularity ?? 0) - (a[1].popularity ?? 0) ||
      (b[1].voteCount ?? 0) - (a[1].voteCount ?? 0);
  });

console.log(`store ${store.size}; candidates ${queue.length}; daily budget ${maxRequests}; ` +
  `TV first, then movies`);
if (process.argv.includes("--dry-run")) {
  for (const [key, rec] of queue.slice(0, 15)) {
    console.log(`  ${key.padEnd(14)} ${String(rec.year || "-").padEnd(5)} ` +
      `votes ${(rec.voteCount ?? 0).toString().padStart(6)} ${rec.title}`);
  }
  process.exit(0);
}

const score100 = (value) => {
  const n = Number(value);
  return Number.isFinite(n) ? Math.max(0, Math.min(100, Math.round(n))) : null;
};
let done = 0;
let scored = 0;
let misses = 0;
let errors = 0;
const started = Date.now();

for (const [recordKey, rec] of queue) {
  if (done >= maxRequests) break;
  const wait = (done + 1) * (1000 / rps) - (Date.now() - started);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  const url = new URL(`${API}/tmdb/${rec.mediaType === "tv" ? "show" : "movie"}/${rec.id}`);
  url.searchParams.set("apikey", apiKey);
  let payload;
  done++;
  try {
    const response = await fetch(url);
    payload = await response.json();
    if (!response.ok || payload?.error) {
      const message = String(payload?.error ?? `HTTP ${response.status}`);
      if (/invalid api key|unauthorized|limit exceeded/i.test(message)) {
        console.error(`fatal: MDBList rejected the request (${message}); stopping after ${done}`);
        process.exitCode = 1;
        break;
      }
      // Unmatched entries / provider misses are not systemic. Record the attempt so old misses
      // don't consume the daily budget repeatedly.
      if (response.status === 404 || /item not found|not found/i.test(message)) {
        misses++;
        appendRecord(outDir, { ...rec, mdblistRatingsAt: Date.now(), fetchedAt: Date.now() });
        continue;
      }
      errors++;
      console.error(`  ${recordKey}: MDBList returned ${message}`);
      continue;
    }
  } catch (error) {
    errors++;
    console.error(`  ${recordKey}: ${String(error.message).replace(apiKey, "[redacted]")}`);
    continue;
  }

  const rating = score100(payload?.ratings?.find((entry) => entry.source === "metacritic")?.score ??
    payload?.ratings?.find((entry) => entry.source === "metacritic")?.value);
  const stamp = Date.now();
  if (rating !== null) scored++;
  else misses++;
  const hasExistingOtherScore = rec.metacriticScore != null && rec.metacriticSource !== "mdblist";
  appendRecord(outDir, {
    ...rec,
    metacriticScore: hasExistingOtherScore ? rec.metacriticScore : (rating ?? rec.metacriticScore ?? null),
    metacriticSource: !hasExistingOtherScore && (rating !== null || rec.metacriticSource === "mdblist")
      ? "mdblist" : rec.metacriticSource,
    mdblistRatingsAt: stamp,
    fetchedAt: stamp,
  });

  if (done % 500 === 0) {
    console.log(`  ${done}/${Math.min(maxRequests, queue.length)} — ${scored} Metacritic scores, ` +
      `${misses} misses, ${errors} errors`);
  }
}

console.log(`done: ${done} requests — ${scored} Metacritic scores, ${misses} misses, ${errors} errors`);
if (errors > Math.max(10, done * 0.05)) process.exitCode = 1;
