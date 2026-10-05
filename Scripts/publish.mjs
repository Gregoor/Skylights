#!/usr/bin/env node
// Publishes the index to the rolling `latest` GitHub Release, as a base + deltas + a manifest.
//
// The index is far past GitHub's 100 MB committed-file limit, but Release assets allow 2 GB, so it
// ships there and the extension fetches it on first use. Release assets have no expiry, so a
// published base stays until it is replaced; deltas are pruned once folded into a new base.
//
// Usage:
//   node Scripts/publish.mjs                                  # bundle only (no index change)
//   node Scripts/publish.mjs --delta=build/delta-2026-09-23.index
//   node Scripts/publish.mjs --base=build/tmdb.index          # republish the base, reset deltas
//   node Scripts/publish.mjs --store=data/records.ndjson.gz   # back the store up as an asset
//
// Needs the `gh` CLI (authenticated; GitHub Actions provides it).

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, mkdtempSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, resolve, join } from "node:path";
import { tmpdir } from "node:os";

import { buildManifest, nextDeltas } from "./manifest.mjs";

const TAG = "latest";
const MANIFEST = "manifest.json";

function argValue(flag) {
  const arg = process.argv.find((a) => a.startsWith(flag));
  return arg ? arg.slice(flag.length) : undefined;
}

const baseArg = argValue("--base=");
const deltaArg = argValue("--delta=");
const storeArg = argValue("--store=");
const bundlePath = resolve(argValue("--bundle=") ?? "build/movies.provider.js");

function gh(args, options = {}) {
  return execFileSync("gh", args, { stdio: "inherit", ...options });
}

function streamHash(path) {
  const hash = createHash("sha256");
  const fd = readFileSync(path); // artifacts are build outputs (tens of MB); fine to read whole
  hash.update(fd);
  return hash.digest("hex");
}

/// The wire artifact. The manifest names the file that gets installed and the bytes it holds; how it
/// travels is this, its gzipped sibling — 12 MB instead of 21 for the base, 4.6 instead of 16 for the
/// Wikipedia one, and that is most of what a client downloads.
function gzipped(path) {
  const target = `${path}.gz`;
  execFileSync("/bin/sh", ["-c", `/usr/bin/gzip -9 -c '${path}' > '${target}'`]);
  return target;
}

function assetInfo(path, name) {
  if (!existsSync(path)) throw new Error(`missing artifact: ${path}`);
  return { name, bytes: statSync(path).size, sha256: streamHash(path), local: resolve(path) };
}

try {
  gh(["release", "view", TAG], { stdio: "ignore" });
} catch {
  gh(["release", "create", TAG, "--title", "Latest index",
    "--notes", "Rolling TMDB index (base + deltas), provider bundle, and store backup."]);
}

// The previous manifest tells us the existing base/deltas to carry forward.
const scratch = mkdtempSync(join(tmpdir(), "tmdb-publish-"));
let prev = null;
try {
  gh(["release", "download", TAG, "-p", MANIFEST, "-D", scratch], { stdio: "ignore" });
  prev = JSON.parse(readFileSync(join(scratch, MANIFEST), "utf8"));
} catch {
  prev = null; // first publish
}

// A new base resets the delta chain; otherwise the deltas accumulate.
const base = baseArg ? assetInfo(baseArg, "tmdb.index") : prev?.base ?? null;
const deltas = nextDeltas({
  prevDeltas: prev?.deltas ?? [],
  isBase: Boolean(baseArg),
  adding: deltaArg ? [assetInfo(deltaArg, basename(deltaArg))] : [],
});
const bundle = assetInfo(bundlePath, "movies.provider.js");
const store = storeArg ? assetInfo(storeArg, "store.ndjson.gz") : prev?.store ?? null;
const manifest = buildManifest({ prev, base, deltas, bundle, store });

// Upload first, then the manifest — so a client never sees a manifest whose assets are missing.
const uploads = [];
if (baseArg) uploads.push(gzipped(baseArg), resolve(baseArg));
if (deltaArg) uploads.push(gzipped(resolve(deltaArg)), resolve(deltaArg));
uploads.push(bundle.local);
if (storeArg) uploads.push(resolve(storeArg));
gh(["release", "upload", TAG, ...uploads, "--clobber"]);

const manifestPath = join(scratch, MANIFEST);
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
gh(["release", "upload", TAG, manifestPath, "--clobber"]);

// Uploading before writing the manifest is what the comment above claims keeps a client from seeing one
// whose assets are missing. Claiming it is not checking it: a manifest naming an asset the release does
// not have breaks every client that reads it, because the sync downloads each path it names and throws
// on the one that is not there — which is how a day of searches returned nothing. So list what the
// release really holds, publish a manifest that only names that, and fail, because a silently short
// publish is what needed catching.
const present = new Set(
  execFileSync("gh", ["release", "view", TAG, "--json", "assets", "--jq", ".assets[].name"], { encoding: "utf8" })
    .split("\n").map((name) => name.trim()).filter(Boolean));
// The manifest names the file that gets installed; the release holds its gzipped sibling, because how an
// asset travels is a detail of getting it there. Checking the plain name alone called every asset that
// travelled that way missing, and trimmed a manifest that was telling the truth.
const has = (asset) => present.has(asset.name) || present.has(`${asset.name}.gz`);
const missing = [base, ...deltas, bundle, store].filter(Boolean).filter((asset) => !has(asset));
if (missing.length > 0) {
  if (base && !has(base)) manifest.base = null;
  manifest.deltas = deltas.filter(has);
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  gh(["release", "upload", TAG, manifestPath, "--clobber"]);
  throw new Error(
    `the release is missing ${missing.map((a) => a.name).join(", ")} — trimmed the manifest to what exists and republished it`);
}

// Prune assets the new manifest no longer references (deltas folded into a fresh base).
const keep = new Set([MANIFEST, base?.name, bundle.name, store?.name,
  ...deltas.map((d) => d.name)].filter(Boolean));
// An asset travels under `<name>.gz` while the manifest names `<name>`, so a keep list built from the
// manifest's names does not match what the release holds. Every delta published since assets started
// travelling that way was deleted by the prune of the very run that uploaded it, with the manifest left
// naming it and the clients failing on it. Kept means the manifest's name, with or without the suffix it
// travels under.
const kept = (name) => keep.has(name) || (name.endsWith(".gz") && keep.has(name.slice(0, -3)));
const listed = execFileSync("gh", ["release", "view", TAG, "--json", "assets", "--jq", ".assets[].name"],
  { encoding: "utf8" }).split("\n").map((s) => s.trim()).filter(Boolean);
for (const name of listed) {
  // The Wikipedia publisher shares this release and prunes its own assets. A sweep here would delete
  // everything this manifest does not happen to know about.
  if (name.startsWith("wikipedia-") || kept(name)) continue;
  console.log(`pruning stale asset ${name}`);
  gh(["release", "delete-asset", TAG, name, "-y"], { stdio: "ignore" });
}

console.log(`published v${manifest.version}: base=${base?.name ?? "none"}, ${deltas.length} delta(s)`);
