#!/usr/bin/env node
// The daily incremental update. Three phases, each appending to the store with a fresh `fetchedAt`
// so `build-delta` picks the day's changes up:
//
//   1. new ids from the export      → fetch metadata
//   2. original-title changes       → free, the export carries the current value
//   3. rolling re-fetch             → the N stalest records, to catch title/poster/vote edits
//
// Records that vanish from the export are handled by build-delta (superseded, no replacement).
// Popularity drift is deliberately NOT an update: the index stores it but scoring never reads it, so
// emitting it would churn the deltas for nothing.
//
// Usage: node Scripts/daily-update.mjs [--out data] [--refetch 5000] [--max-new 0] [--requests-per-second 20]

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { readStore, key, appendRecord, forEachLine } from "./store.mjs";
import { createClient, fetchInto, hasCredentials } from "./fetch.mjs";

if (!hasCredentials()) {
  console.error("set TMDB_READ_TOKEN (v4 bearer) or TMDB_API_KEY (v3) in the environment");
  process.exit(2);
}

// Detached runs outlive whatever was reading their log; a write to a closed pipe must not kill them.
for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});

function argValue(flag) {
  const arg = process.argv.find((a) => a.startsWith(flag));
  return arg ? arg.slice(flag.length) : undefined;
}

const outDir = resolve(argValue("--out=") ?? "data");
const refetchLimit = Number(argValue("--refetch=") ?? 5000);
const maxNew = Number(argValue("--max-new=") ?? 0); // 0 = all
const rps = Number(argValue("--requests-per-second=") ?? 20);

const exportEntries = [];
forEachLine(resolve(outDir, "id-export.ndjson"), (line) => {
  const parsed = JSON.parse(line);
  if (parsed.adult) return; // family-safe surfaces only, same rule as the backfill
  exportEntries.push(parsed);
});

const store = readStore(outDir);
console.log(`store has ${store.size}; export has ${exportEntries.length}`);

// 1. New ids.
const toFetch = exportEntries.filter((e) => !store.has(key(e.mediaType, e.id)));
if (maxNew > 0) toFetch.length = Math.min(toFetch.length, maxNew);

// 2. Free original-title changes — the export always carries the current one.
const retitled = new Set();
for (const e of exportEntries) {
  const k = key(e.mediaType, e.id);
  const rec = store.get(k);
  if (!rec) continue;
  const next = (e.originalTitle ?? "").trim();
  if (next && next !== rec.originalTitle) {
    appendRecord(outDir, { ...rec, originalTitle: next, fetchedAt: Date.now() });
    retitled.add(k);
  }
}

// 3. Rolling re-fetch of the stalest records, skipping the ones we just refreshed above.
const stalest = [...store.values()]
  .filter((r) => !retitled.has(key(r.mediaType, r.id)))
  .sort((a, b) => {
    const needsSeasonCount = (r) => r.mediaType === "tv" && !Number.isInteger(r.seasonCount);
    if (needsSeasonCount(a) !== needsSeasonCount(b)) return needsSeasonCount(a) ? -1 : 1;
    return (a.fetchedAt ?? 0) - (b.fetchedAt ?? 0);
  })
  .slice(0, refetchLimit)
  .map((r) => ({ mediaType: r.mediaType, id: r.id }));

console.log(`new ${toFetch.length}, retitled ${retitled.size}, re-fetching ${stalest.length}`);

const client = createClient({ rps });
const fetched = await fetchInto(toFetch, { outDir, client, label: "new" });
const refreshed = await fetchInto(stalest, { outDir, client, label: "refresh" });

const errors = fetched.errors + refreshed.errors;
console.log(
  `done: new ${fetched.done} (${fetched.skipped404} 404s), retitled ${retitled.size}, refreshed ${refreshed.done}`);
if (errors > 0) process.exitCode = 1;
