import { createReadStream, createWriteStream, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createGunzip } from "node:zlib";
import { spawnSync } from "node:child_process";

const database = "skylights-tmdb-search";
const batchSize = 100;
const maxStatementBytes = 80_000;

function argument(name) {
  const prefix = "--" + name + "=";
  const found = process.argv.find((value) => value.startsWith(prefix));
  return found ? found.slice(prefix.length) : undefined;
}

function sqlText(value) {
  return value == null ? "NULL" : "'" + String(value).replaceAll("'", "''") + "'";
}

function readJsonOutput(stdout) {
  const start = stdout.search(/[\[{]/);
  if (start < 0) throw new Error("Wrangler did not return JSON: " + stdout.slice(0, 300));
  return JSON.parse(stdout.slice(start));
}

function wrangler(args, options = {}) {
  const result = spawnSync("node", [
    "/Users/gregor/.npm/_npx/c943b712072b77c4/node_modules/wrangler/bin/wrangler.js",
    ...args,
  ], {
    cwd: resolve(import.meta.dirname),
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: options.capture ? "pipe" : "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("Wrangler exited with status " + result.status);
  return options.capture ? result.stdout : "";
}

async function* lines(stream) {
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

function score(value) {
  if (value == null) return "NULL";
  const number = Number(value);
  return Number.isFinite(number) ? String(Math.max(0, Math.min(100, Math.trunc(number)))) : "NULL";
}

const source = argument("source");
if (!source) {
  console.error("Usage: node backfill-ratings.mjs --source=/path/to/store.ndjson.gz");
  process.exit(2);
}

const queried = wrangler([
  "d1", "execute", database, "--remote", "--json",
  "--command", "SELECT COUNT(*) AS title_count FROM titles",
], { capture: true });
const parsedQuery = readJsonOutput(queried);
const queryResult = Array.isArray(parsedQuery) ? parsedQuery[0] : parsedQuery;
const titleCount = Number(queryResult?.results?.[0]?.title_count);
if (!Number.isFinite(titleCount) || titleCount <= 0) throw new Error("D1 title table is empty");

const latest = new Map();
let scanned = 0;
const input = createReadStream(source).pipe(createGunzip());
for await (const line of lines(input)) {
  const record = JSON.parse(line);
  const id = Number(record.id);
  if (!Number.isSafeInteger(id) || id <= 0) continue;
  const mediaType = record.mediaType === "tv" ? "tv" : "movie";
  latest.set(mediaType + ":" + id, {
    id,
    mediaType,
    rtScore: record.rtScore,
    metacriticScore: record.metacriticScore,
    imdbRating: record.imdbRating,
    metacriticSource: record.metacriticSource,
    ratingsAt: record.ratingsAt,
    mdblistRatingsAt: record.mdblistRatingsAt,
  });
  scanned++;
}

console.log("Scanned " + scanned.toLocaleString() + " store records; " +
  latest.size.toLocaleString() + " latest titles.");
if (latest.size < titleCount * 0.95) {
  throw new Error("Snapshot is unexpectedly smaller than D1 (" + latest.size + " vs " + titleCount + ")");
}

const temporaryDirectory = mkdtempSync(join(tmpdir(), "tmdb-rating-backfill-"));
const sqlPath = join(temporaryDirectory, "ratings.sql");
const output = createWriteStream(sqlPath);
let batch = [];
let batchBytes = 0;
let changedCandidates = 0;

function write(text) {
  if (!output.write(text)) return new Promise((resolveWrite) => output.once("drain", resolveWrite));
  return Promise.resolve();
}

async function flush() {
  if (batch.length === 0) return;
  const statement =
    "WITH incoming(id, media_type, rt_score, metacritic_score, imdb_rating, metacritic_source, ratings_at, mdblist_ratings_at) AS (VALUES " +
    batch.join(",") +
    ") UPDATE titles SET rt_score=incoming.rt_score, " +
    "metacritic_score=incoming.metacritic_score, imdb_rating=incoming.imdb_rating, " +
    "metacritic_source=incoming.metacritic_source, ratings_at=incoming.ratings_at, " +
    "mdblist_ratings_at=incoming.mdblist_ratings_at FROM incoming " +
    "WHERE titles.id=incoming.id AND titles.media_type=incoming.media_type;\n";
  await write(statement);
  batch = [];
  batchBytes = 0;
}

try {
  for (const record of latest.values()) {
    const hasRating = record.rtScore != null || record.metacriticScore != null ||
      record.imdbRating != null || record.ratingsAt != null || record.mdblistRatingsAt != null;
    if (!hasRating) continue;
    const tuple = "(" + Number(record.id) + ", '" + record.mediaType + "', " +
      score(record.rtScore) + ", " + score(record.metacriticScore) + ", " +
      score(record.imdbRating) + ", " + sqlText(record.metacriticSource) + ", " +
      (Number(record.ratingsAt) || 0) + ", " + (Number(record.mdblistRatingsAt) || 0) + ")";
    const tupleBytes = Buffer.byteLength(tuple) + (batch.length ? 1 : 0);
    if (batch.length >= batchSize || batchBytes + tupleBytes > maxStatementBytes) await flush();
    batch.push(tuple);
    batchBytes += tupleBytes;
    changedCandidates++;
  }
  await flush();
  await new Promise((resolveWrite, rejectWrite) => {
    output.end(resolveWrite);
    output.on("error", rejectWrite);
  });

  console.log("Uploading rating snapshots for " + changedCandidates.toLocaleString() + " titles to D1…");
  wrangler(["d1", "execute", database, "--remote", "--file=" + sqlPath]);
  console.log("D1 rating backfill complete.");
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
