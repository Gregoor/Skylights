#!/usr/bin/env node
// Builds a delta index: the records touched since a marker (new + updated), plus the stable keys it
// supersedes (those touched records, and anything dropped from the export). The delta is an index in
// the same format, so the client searches base + deltas and merges — no renumbering, no binary patch.
//
//   node Scripts/build-delta.mjs [data-dir] [out.index] [--since=<unix-ms>]
//
// `--since` defaults to the marker in <data-dir>/published.json (written by --mark). Records carry
// `fetchedAt`, so "touched since T" is exact; a matching record removed from today's export is
// superseded with no replacement.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { buildIndexFromRecords } from "./build-index.mjs";
import { stableKey, key as recordKey, readStore, forEachLine } from "./store.mjs";
import { inBand } from "./band.mjs";

const dir = resolve(process.argv[2] ?? "data");
const out = resolve(process.argv[3] ?? "build/delta.index");
const sinceArg = process.argv.find((a) => a.startsWith("--since="));
const markArg = process.argv.includes("--mark");
// Marking without building: the marker is what the next delta measures from, so it has to move only once
// this run's delta is really published. Marking while building loses a day's changes for good if the
// publish then fails, because the next delta starts after them.
const markOnly = process.argv.includes("--mark-only");

const markerPath = resolve(dir, "published.json");
const marker = existsSync(markerPath) ? JSON.parse(readFileSync(markerPath, "utf8")) : {};
const since = sinceArg ? Number(sinceArg.slice("--since=".length)) : Number(marker.since ?? 0);

if (markOnly) {
  writeFileSync(markerPath, JSON.stringify({ since: Date.now() }));
  console.log(`marked published.json — the delta it measures from is published`);
  process.exit(0);
}

// Last-wins per key, through the same streaming reader every other tool uses.
const latest = readStore(dir);

// Today's export ids, to spot records that vanished (rare, but a deletion must supersede too).
const liveExport = new Set();
forEachLine(resolve(dir, "id-export.ndjson"), (line) => {
  const e = JSON.parse(line);
  if (!e.adult) liveExport.add(recordKey(e.mediaType, e.id));
});

const touched = [];
const superseded = new Set();
for (const [k, rec] of latest) {
  const live = liveExport.size === 0 || liveExport.has(k);
  if (!live) {
    // Gone from the export: supersede the key and ship no replacement, whether or not it was touched.
    superseded.add(stableKey(rec.mediaType, rec.id));
  } else if ((rec.fetchedAt ?? 0) > since) {
    // Supersede it either way — if it was in the base the client must drop the stale row — but only
    // ship it if the base would hold it, so a delta cannot smuggle in rows the base excludes.
    if (inBand(rec)) touched.push(rec);
    superseded.add(stableKey(rec.mediaType, rec.id));
  }
}

if (touched.length === 0 && superseded.size === 0) {
  console.log("delta: nothing changed since the marker");
} else {
  const built = await buildIndexFromRecords(touched, out, { supersededKeys: [...superseded] });
  console.log(
    `delta: ${built.rows} records, ${superseded.size} superseded keys → ${out}`);
}

if (markArg) {
  writeFileSync(markerPath, JSON.stringify({ since: Date.now(), delta: out }));
  console.log(`marked published.json since=${new Date().toISOString()}`);
}
