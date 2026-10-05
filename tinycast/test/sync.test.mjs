// Index sync correctness: a manifest version bump must download only what actually changed, a
// corrupt local file must refetch, and a base republish must prune the deltas it folded in.
//
//   node tinycast/test/sync.test.mjs

import { mkdirSync, rmSync, writeFileSync, readFileSync, copyFileSync, appendFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { gzipSync, gunzipSync } from "node:zlib";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

import { syncIndexes } from "../db/index-sync.mjs";

let pass = 0;
let fail = 0;
const check = (label, ok, extra = "") => {
  if (ok) pass++;
  else {
    fail++;
    console.log(`  FAIL ${label}${extra ? ` — ${extra}` : ""}`);
  }
};

const root = resolve(tmpdir(), "tmdb-sync");
rmSync(root, { recursive: true, force: true });
const serveDir = resolve(root, "serve");
const cacheDir = resolve(root, "cache");
mkdirSync(serveDir, { recursive: true });

const sha = (name) => createHash("sha256").update(readFileSync(join(serveDir, name))).digest("hex");
const asset = (name, bytes) => ({ name, bytes, sha256: sha(name) });

// "Publish" a set of assets + a manifest version into the served directory.
function publish(version, { base, deltas }) {
  const manifest = {
    version,
    base: base ? asset("tmdb.index") : null,
    deltas: deltas.map((n) => asset(n)),
  };
  writeFileSync(join(serveDir, "manifest.json"), JSON.stringify(manifest));
}
/// Write an asset the way `publish.mjs` does: the raw file the manifest describes, plus the gzipped
/// sibling a client actually downloads.
function serve(name, contents) {
  writeFileSync(join(serveDir, name), contents);
  writeFileSync(join(serveDir, `${name}.gz`), gzipSync(Buffer.from(contents)));
}
serve("tmdb.index", "base-v1 ".repeat(500));
serve("delta-1.index", "d1 ".repeat(50));
serve("delta-2.index", "d2 ".repeat(50));
const baseV2 = "base-v2 ".repeat(700);

const downloads = [];
const download = (url, path) => {
  const name = url.slice(url.lastIndexOf("/") + 1);
  downloads.push(name);
  copyFileSync(join(serveDir, name), path);
};
const hash = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
const gunzip = (from, to) => writeFileSync(to, gunzipSync(readFileSync(from)));
const sync = () => syncIndexes({
  manifestURL: "https://example.test/movies/manifest.json", cacheDir, fs: { ...fsShim }, download,
  gunzip, hash,
});

// A tiny stand-in for the runtime fs shim, backed by node.
import * as nodeFs from "node:fs";
const fsShim = {
  mkdirSync: (p, o) => nodeFs.mkdirSync(p, o),
  existsSync: (p) => nodeFs.existsSync(p),
  readFileSync: (p, e) => nodeFs.readFileSync(p, e),
  writeFileSync: (p, d) => nodeFs.writeFileSync(p, d),
  readdirSync: (p) => nodeFs.readdirSync(p),
  rmSync: (p, o) => nodeFs.rmSync(p, o),
};

// 1. First sync: base + one delta.
publish(1, { base: true, deltas: ["delta-1.index"] });
let paths = await sync();
check("returns base then deltas in order",
  paths.length === 2 && paths[0].endsWith("tmdb.index") && paths[1].endsWith("delta-1.index"),
  paths.join(" | "));
check("first sync downloads manifest + base + delta",
  downloads.join(",") === "manifest.json,tmdb.index.gz,delta-1.index.gz", downloads.join(","));

// 2. Same manifest again: the manifest alone.
downloads.length = 0;
await sync();
check("unchanged manifest re-downloads nothing but the manifest",
  downloads.join(",") === "manifest.json", downloads.join(","));

// 3. A day's delta arrives: only the new delta is fetched, not the base.
downloads.length = 0;
publish(2, { base: true, deltas: ["delta-1.index", "delta-2.index"] });
paths = await sync();
check("a new delta pulls only that delta",
  downloads.join(",") === "manifest.json,delta-2.index.gz", downloads.join(","));
check("all three indexes reported",
  paths.length === 3 && paths[2].endsWith("delta-2.index"), paths.join(" | "));

// 4. A corrupt local file is refetched rather than served.
downloads.length = 0;
appendFileSync(join(cacheDir, "delta-1.index"), "garbage");
await sync();
check("a corrupted index is refetched",
  downloads.join(",") === "manifest.json,delta-1.index.gz", downloads.join(","));

// 5. A base republish resets the chain and prunes the folded deltas.
downloads.length = 0;
serve("tmdb.index", baseV2);
publish(3, { base: true, deltas: [] });
paths = await sync();
check("a new base is fetched", downloads.includes("tmdb.index.gz"), downloads.join(","));
check("deltas are not refetched on a base republish",
  !downloads.includes("delta-1.index.gz") && !downloads.includes("delta-2.index.gz"), downloads.join(","));
check("folded deltas are pruned from the cache",
  !nodeFs.existsSync(join(cacheDir, "delta-1.index")) && !nodeFs.existsSync(join(cacheDir, "delta-2.index")),
  nodeFs.readdirSync(cacheDir).join(","));
check("only the base remains", paths.length === 1 && paths[0].endsWith("tmdb.index"), paths.join(" | "));

// Pruning must only remove assets we installed. Anything else in this directory is the user's — a
// config file, a key — and a sweep that deletes those would take their settings with it.
writeFileSync(join(cacheDir, "config.json"), JSON.stringify({ ratings: { movie: "rt" } }));
serve("delta-2.index", readFileSync(join(serveDir, "delta-1.index"), "utf8"));
publish(4, { base: true, deltas: ["delta-1.index", "delta-2.index"] });
await sync();
check("a file we did not install survives a pruning sync",
  nodeFs.existsSync(join(cacheDir, "config.json")), nodeFs.readdirSync(cacheDir).join(","));
check("...and it still holds the user's content",
  JSON.parse(readFileSync(join(cacheDir, "config.json"), "utf8")).ratings.movie === "rt");

// 6. A release from before the convention has no gzipped sibling; the raw asset must still install.
downloads.length = 0;
rmSync(join(serveDir, "delta-1.index.gz"), { force: true });
appendFileSync(join(cacheDir, "delta-1.index"), "garbage");
await sync();
check("an asset with no .gz falls back to the uncompressed one",
  downloads.join(",") === "manifest.json,delta-1.index.gz,delta-1.index", downloads.join(","));
check("...and installs it correctly",
  hash(join(cacheDir, "delta-1.index")) === sha("delta-1.index"));

console.log(`\n${pass} passed, ${fail} failed`);
rmSync(root, { recursive: true, force: true });
process.exit(fail ? 1 : 0);