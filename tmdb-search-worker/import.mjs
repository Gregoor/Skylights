#!/usr/bin/env node
import { createReadStream, createWriteStream, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createGunzip } from "node:zlib";
import { spawnSync } from "node:child_process";

const database = "skylights-tmdb-search";
const batchSize = 100;
const maxStatementBytes = 80_000;

function argument(name) {
  const prefix = `--${name}=`;
  const found = process.argv.find((value) => value.startsWith(prefix));
  return found?.slice(prefix.length);
}

function sqlText(value) {
  return `'${String(value ?? "").replaceAll("'", "''")}'`;
}

function sqlNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? String(number) : "0";
}

function foldText(value) {
  return String(value ?? "").normalize("NFD").replace(/\p{M}+/gu, "")
    .toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function values(record) {
  const mediaType = record.mediaType === "tv" ? "tv" : "movie";
  const title = String(record.title ?? "");
  const originalTitle = String(record.originalTitle ?? "");
  return `(${sqlNumber(record.id)}, ${sqlText(mediaType)}, ${sqlText(record.title)}, ` +
    `${sqlText(record.originalTitle)}, ${sqlNumber(record.year)}, ${sqlNumber(record.voteCount)}, ` +
    `${sqlNumber(record.popularity)}, ${sqlText(record.posterPath)}, ${sqlText(record.imdbId)}, ` +
    `${sqlNumber(record.seasonCount)}, ${sqlText(foldText(title))}, ${sqlText(foldText(originalTitle))}, ` +
    `${sqlNumber(record.fetchedAt)})`;
}

function readJsonOutput(stdout) {
  const start = stdout.search(/[\[{]/);
  if (start < 0) throw new Error(`Wrangler did not return JSON: ${stdout.slice(0, 300)}`);
  return JSON.parse(stdout.slice(start));
}

function wrangler(args, { capture = false } = {}) {
  const result = spawnSync("npx", ["--yes", "wrangler@4", ...args], {
    cwd: resolve(import.meta.dirname),
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: capture ? "pipe" : "inherit"
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Wrangler exited with status ${result.status}`);
  return capture ? result.stdout : "";
}

async function* ndjsonLines(stream) {
  let carry = Buffer.alloc(0);
  for await (const chunk of stream) {
    const data = carry.length ? Buffer.concat([carry, chunk]) : chunk;
    let start = 0;
    for (let index = 0; index < data.length; index++) {
      if (data[index] !== 0x0a) continue;
      const line = data.subarray(start, index).toString("utf8").replace(/\r$/, "");
      if (line) yield line;
      start = index + 1;
    }
    carry = Buffer.from(data.subarray(start));
  }
  const tail = carry.toString("utf8").replace(/\r$/, "");
  if (tail) yield tail;
}

const source = argument("source");
if (!source || !existsSync(source)) {
  console.error("Usage: node import.mjs --source=/path/to/store.ndjson[.gz]");
  process.exit(2);
}

const query = wrangler([
  "d1", "execute", database, "--remote", "--json",
  "--command", "SELECT COALESCE((SELECT value FROM sync_state WHERE key = 'fetched_at'), '0') AS fetched_at"
], { capture: true });
const parsedQuery = readJsonOutput(query);
const queryResult = Array.isArray(parsedQuery) ? parsedQuery[0] : parsedQuery;
const checkpoint = Number(queryResult?.results?.[0]?.fetched_at ?? 0);
if (!Number.isFinite(checkpoint)) throw new Error("Could not read the D1 import checkpoint");

const input = createReadStream(source);
const changed = new Map();
let maxFetchedAt = checkpoint;
let scanned = 0;
for await (const line of ndjsonLines(source.endsWith(".gz") ? input.pipe(createGunzip()) : input)) {
  scanned++;
  const record = JSON.parse(line);
  const fetchedAt = Number(record.fetchedAt) || 0;
  maxFetchedAt = Math.max(maxFetchedAt, fetchedAt);
  if (fetchedAt < checkpoint) continue;
  const mediaType = record.mediaType === "tv" ? "tv" : "movie";
  changed.set(`${mediaType}:${record.id}`, record);
}

console.log(`Scanned ${scanned.toLocaleString()} store rows; ${changed.size.toLocaleString()} records need syncing.`);
if (changed.size === 0) process.exit(0);

const temporaryDirectory = mkdtempSync(join(tmpdir(), "tmdb-d1-import-"));
const sqlPath = join(temporaryDirectory, "import.sql");
const output = createWriteStream(sqlPath);
let batch = [];
let batchBytes = 0;

function write(text) {
  if (!output.write(text)) return new Promise((resolveWrite) => output.once("drain", resolveWrite));
  return Promise.resolve();
}

async function flush() {
  if (batch.length === 0) return;
  const statement = `INSERT INTO titles (id, media_type, title, original_title, year, vote_count, popularity, poster_path, imdb_id, season_count, title_folded, original_title_folded, fetched_at) VALUES ${batch.join(",")} ON CONFLICT(media_type, id) DO UPDATE SET title=excluded.title, original_title=excluded.original_title, year=excluded.year, vote_count=excluded.vote_count, popularity=excluded.popularity, poster_path=excluded.poster_path, imdb_id=excluded.imdb_id, season_count=excluded.season_count, title_folded=excluded.title_folded, original_title_folded=excluded.original_title_folded, fetched_at=excluded.fetched_at WHERE excluded.fetched_at >= titles.fetched_at;\n`;
  await write(statement);
  batch = [];
  batchBytes = 0;
}

try {
  for (const record of changed.values()) {
    const tuple = values(record);
    const tupleBytes = Buffer.byteLength(tuple) + (batch.length ? 1 : 0);
    if (batch.length >= batchSize || batchBytes + tupleBytes > maxStatementBytes) await flush();
    batch.push(tuple);
    batchBytes += tupleBytes;
  }
  await flush();
  await write(`INSERT INTO sync_state(key, value) VALUES ('fetched_at', ${sqlText(maxFetchedAt)}) ON CONFLICT(key) DO UPDATE SET value=excluded.value;\n`);
  await new Promise((resolveWrite, rejectWrite) => {
    output.end(resolveWrite);
    output.on("error", rejectWrite);
  });

  console.log(`Uploading ${sqlPath} to D1…`);
  wrangler(["d1", "execute", database, "--remote", `--file=${sqlPath}`]);
  console.log(`D1 sync complete through fetchedAt=${maxFetchedAt}.`);
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
