#!/usr/bin/env node
import { createReadStream, createWriteStream, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createGunzip } from "node:zlib";
import { spawnSync } from "node:child_process";

const database = "skylights-tmdb-search";
const rowsPerStatement = 100;
const rowsPerImport = 50_000;
const maxStatementBytes = 80_000;

function argument(name) {
  const prefix = `--${name}=`;
  const found = process.argv.find((value) => value.startsWith(prefix));
  return found?.slice(prefix.length);
}

function sqlText(value) {
  return `'${String(value ?? "").replaceAll("'", "''")}'`;
}

function foldText(value) {
  return String(value ?? "").normalize("NFD").replace(/\p{M}+/gu, "")
    .toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function wrangler(args) {
  const result = spawnSync("node", [
    "/Users/gregor/.npm/_npx/c943b712072b77c4/node_modules/wrangler/bin/wrangler.js",
    ...args,
  ], {
    cwd: resolve(import.meta.dirname),
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Wrangler exited with status ${result.status}`);
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

const source = argument("source");
if (!source) {
  console.error("Usage: node backfill-folded-titles.mjs --source=/path/to/store.ndjson.gz");
  process.exit(2);
}

const latest = new Map();
let scanned = 0;
for await (const line of lines(createReadStream(source).pipe(createGunzip()))) {
  const record = JSON.parse(line);
  const id = Number(record.id);
  if (!Number.isSafeInteger(id) || id <= 0) continue;
  const mediaType = record.mediaType === "tv" ? "tv" : "movie";
  latest.set(`${mediaType}:${id}`, {
    id,
    mediaType,
    titleFolded: foldText(record.title),
    originalTitleFolded: foldText(record.originalTitle),
  });
  scanned++;
}

console.log(`Scanned ${scanned.toLocaleString()} records; ${latest.size.toLocaleString()} latest titles.`);
const temporaryDirectory = mkdtempSync(join(tmpdir(), "tmdb-folded-backfill-"));
let importNumber = 0;
let importRows = 0;
let sqlPath;
let output;
let batch = [];
let batchBytes = 0;
let statements = 0;

function openFile() {
  sqlPath = join(temporaryDirectory, `folded-${String(importNumber).padStart(4, "0")}.sql`);
  output = createWriteStream(sqlPath);
}

function write(text) {
  if (!output.write(text)) return new Promise((resume) => output.once("drain", resume));
  return Promise.resolve();
}

async function flushBatch() {
  if (batch.length === 0) return;
  await write(`WITH incoming(id, media_type, title_folded, original_title_folded) AS (VALUES ${batch.join(",")})
    UPDATE titles SET title_folded=incoming.title_folded,
      original_title_folded=incoming.original_title_folded FROM incoming
    WHERE titles.media_type=incoming.media_type AND titles.id=incoming.id
      AND (titles.title_folded IS NOT incoming.title_folded
        OR titles.original_title_folded IS NOT incoming.original_title_folded);\n`);
  statements++;
  batch = [];
  batchBytes = 0;
}

async function finishImport() {
  await flushBatch();
  if (statements === 0) return;
  await new Promise((resume, reject) => {
    output.end(resume);
    output.on("error", reject);
  });
  console.log(`Uploading folded-title batch ${importNumber + 1} (${importRows.toLocaleString()} titles)…`);
  wrangler(["d1", "execute", database, "--remote", `--file=${sqlPath}`]);
  importNumber++;
  importRows = 0;
  statements = 0;
  output = null;
}

try {
  openFile();
  for (const record of latest.values()) {
    const tuple = `(${record.id}, ${sqlText(record.mediaType)}, ${sqlText(record.titleFolded)}, ${sqlText(record.originalTitleFolded)})`;
    const tupleBytes = Buffer.byteLength(tuple) + (batch.length ? 1 : 0);
    if (batch.length >= rowsPerStatement || batchBytes + tupleBytes > maxStatementBytes) await flushBatch();
    batch.push(tuple);
    batchBytes += tupleBytes;
    importRows++;
    if (importRows >= rowsPerImport) {
      await finishImport();
      openFile();
    }
  }
  await finishImport();
  console.log(`Folded-title backfill complete: ${latest.size.toLocaleString()} titles.`);
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
