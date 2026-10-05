#!/usr/bin/env node
// Backfills Metacritic scores from MDBList for indexed TMDB movies and shows. OMDb's Metascore
// coverage is especially sparse for TV; MDBList returns ratings against our native TMDB ids. Its
// batch endpoint resolves up to 200 IDs per read.
//
// The store is append-only, so this resumes safely after a daily quota or interrupted run. A score
// already provided by OMDb is kept. MDBList misses are timestamped and only retried for recent titles.
//
//   MDBLIST_API_KEY=... node Scripts/fetch-mdblist-ratings.mjs [--max-requests=10000]
//     [--requests-per-second=1] [--refresh-days=30] [--out=data]

import { readStore, appendRecord } from "./store.mjs";
import { inBand } from "./band.mjs";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

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
// MDBList caps account reads at 1,000 per fixed five-minute window. Leave room for other apps.
const rps = Number(argValue("--requests-per-second=") ?? 1);
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
let attempts = 0;
let scored = 0;
let misses = 0;
let errors = 0;
let dailyLimitReached = false;
const started = Date.now();

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function requestJson(url, options = {}) {
  for (;;) {
    if (done >= maxRequests) return null;
    const wait = (attempts + 1) * (1000 / rps) - (Date.now() - started);
    if (wait > 0) await pause(wait);
    attempts++;

    let response;
    try {
      response = await fetch(url, options);
    } catch (error) {
      errors++;
      console.error(`  MDBList request failed: ${String(error.message).replace(apiKey, "[redacted]")}`);
      return null;
    }

    let payload;
    try {
      payload = await response.json();
    } catch {
      if (response.status === 429) payload = {};
      else {
        errors++;
        console.error(`  MDBList returned non-JSON HTTP ${response.status}`);
        return null;
      }
    }

    const message = String(payload?.error ?? `HTTP ${response.status}`);
    if (response.status === 429 || /API rate limit exceeded|Daily API limit exceeded/i.test(message)) {
      if (/Daily API limit exceeded/i.test(message)) {
        console.log(`daily MDBList quota reached after ${done} successful responses; saving today's work`);
        dailyLimitReached = true;
        return null;
      }
      const retryAfter = Number(response.headers.get("retry-after")) || 60;
      console.log(`MDBList shared read limit reached; retrying after ${retryAfter}s`);
      await pause(retryAfter * 1000);
      continue;
    }

    done++;
    return { response, payload, message };
  }
}

// MDBList's cursor feed identifies recently changed titles, including rating changes. Start from
// the last successfully published delta marker; a cold cache uses a two-day overlap.
const changedKeys = new Set();
if (!process.argv.includes("--dry-run")) {
  const markerPath = resolve(outDir, "published.json");
  let since = new Date(now - 2 * dayMs).toISOString();
  if (existsSync(markerPath)) {
    try {
      const marker = JSON.parse(readFileSync(markerPath, "utf8"));
      if (Number(marker.since) > 0) since = new Date(Number(marker.since)).toISOString();
    } catch { /* use the overlap window */ }
  }

  for (const [mediaType, endpoint, field] of [
    ["tv", "shows", "shows"], ["movie", "movies", "movies"],
  ]) {
    let cursor;
    for (;;) {
      const url = new URL(`${API}/${endpoint}/updates`);
      url.searchParams.set("apikey", apiKey);
      url.searchParams.set("limit", "100");
      if (cursor) url.searchParams.set("cursor", cursor);
      else url.searchParams.set("since", since);
      const result = await requestJson(url);
      if (!result) break;
      if (!result.response.ok || result.payload?.error) {
        if (/invalid api key|unauthorized/i.test(result.message)) {
          console.error(`fatal: MDBList rejected the request (${result.message}); stopping`);
          process.exitCode = 1;
        } else {
          errors++;
          console.error(`  ${endpoint} update feed: ${result.message}`);
        }
        break;
      }
      for (const item of result.payload?.[field] ?? []) {
        const id = Number(item?.ids?.tmdb ?? item?.tmdb ?? item?.tmdbid ?? item?.tmdb_id);
        if (Number.isSafeInteger(id) && id > 0) changedKeys.add(`${mediaType}:${id}`);
      }
      const page = result.payload?.pagination ?? {};
      if (!page.has_more || !page.next_cursor) break;
      cursor = page.next_cursor;
    }
    if (dailyLimitReached || process.exitCode) break;
  }

  const queued = new Set(queue.map(([key]) => key));
  for (const key of changedKeys) {
    const rec = store.get(key);
    if (!rec || queued.has(key) || (!inBand(rec) && !isRecent(rec)) ||
        (rec.metacriticScore != null && rec.metacriticSource !== "mdblist")) continue;
    queue.push([key, rec]);
  }
  queue.sort((a, b) =>
    ((b[1].mediaType === "tv") - (a[1].mediaType === "tv")) ||
    Number(changedKeys.has(b[0])) - Number(changedKeys.has(a[0])) ||
    Number(isRecent(b[1])) - Number(isRecent(a[1])) ||
    (b[1].popularity ?? 0) - (a[1].popularity ?? 0) ||
    (b[1].voteCount ?? 0) - (a[1].voteCount ?? 0));
  console.log(`MDBList updates since ${since}: ${changedKeys.size} known titles`);
}

// Batch lookup returns ratings for up to 200 TMDB ids per read request.
const batches = [];
for (const [recordKey, rec] of queue) {
  const mediaType = rec.mediaType === "tv" ? "show" : "movie";
  let batch = batches.at(-1);
  if (!batch || batch.mediaType !== mediaType || batch.records.length === 200) {
    batch = { mediaType, records: [] };
    batches.push(batch);
  }
  batch.records.push([recordKey, rec]);
}

for (const batch of batches) {
  if (done >= maxRequests || dailyLimitReached || process.exitCode) break;
  const url = new URL(`${API}/tmdb/${batch.mediaType}`);
  url.searchParams.set("apikey", apiKey);
  const result = await requestJson(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ids: batch.records.map(([, rec]) => rec.id) }),
  });
  if (!result) break;
  const { response, payload, message } = result;
  if (!response.ok || payload?.error || !Array.isArray(payload)) {
    if (/invalid api key|unauthorized/i.test(message)) {
      console.error(`fatal: MDBList rejected the request (${message}); stopping after ${done} reads`);
      process.exitCode = 1;
      break;
    }
    errors++;
    console.error(`  ${batch.mediaType}: MDBList returned ${message}`);
    continue;
  }

  const byTmdbId = new Map(payload.map((item) => [
    Number(item?.ids?.tmdb ?? item?.tmdbid ?? item?.tmdb_id), item,
  ]));
  for (const [recordKey, rec] of batch.records) {
    const item = byTmdbId.get(rec.id);
    if (!item) {
      misses++;
      const stamp = Date.now();
      appendRecord(outDir, { ...rec, mdblistRatingsAt: stamp, fetchedAt: stamp });
      continue;
    }
    const rating = score100(item?.ratings?.find((entry) => entry.source === "metacritic")?.score ??
      item?.ratings?.find((entry) => entry.source === "metacritic")?.value);
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
  }

  if (done % 100 === 0) {
    console.log(`  ${done}/${Math.min(maxRequests, batches.length)} batch requests — ` +
      `${scored} Metacritic scores, ${misses} misses, ${errors} errors`);
  }
}

console.log(`done: ${done} successful API reads (${attempts} attempts) — ` +
  `${scored} Metacritic scores, ${misses} misses, ${errors} errors`);
if (errors > Math.max(10, done * 0.05)) process.exitCode = 1;
