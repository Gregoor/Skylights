// The Wikipedia provider's cross-language merge: a row that arrived in a delta is grouped with its
// counterparts by stable id even though it sits at a different position than the base row, and a
// sibling the query never matched is read back from its base row.
//
//   node tinycast/test/wikipedia-provider.test.mjs

import { registerHooks } from "node:module";
import { mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { buildIndexFromRecords } from "../../Scripts/build-index.mjs";
import { MovieIndex } from "../../src/db/loader.mjs";
import { openNodeReader } from "../../src/db/loaders.mjs";
import { openGroups } from "../../src/wikipedia/groups.mjs";

// `provider.js` is bundled against the app runtime's `@tinycast/api`, which is not installed here. The
// merge under test touches neither of its two functions, so a stub lets the module import.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@tinycast/api") {
      return {
        url: "data:text/javascript,export function registerRootSearchProvider() {}; export function open() {}",
        shortCircuit: true,
      };
    }
    return nextResolve(specifier, context);
  },
});

const dir = resolve(tmpdir(), "tmdb-wikipedia-provider");
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });
process.env.TINYCAST_PROVIDER_CACHE = resolve(dir, "cache");
const { mergeLanguages } = await import("../wikipedia/provider.js");

let pass = 0;
let fail = 0;
const check = (label, ok, extra = "") => {
  if (ok) pass += 1;
  else {
    fail += 1;
    console.log(`  FAIL ${label}${extra ? ` — ${extra}` : ""}`);
  }
};

const record = (id, title) => ({
  mediaType: "movie", id, title, originalTitle: title, year: 2000,
  voteCount: 10, popularity: 10, posterPath: "", imdbId: "",
});

const enPath = resolve(dir, "en.index");
await buildIndexFromRecords([record(500000, "New York City")], enPath, { verbose: false });
const esPath = resolve(dir, "es.index");
await buildIndexFromRecords([record(100, "Otro"), record(400000, "Nueva York")], esPath, { verbose: false });

const bands = [
  { language: "en", index: await new MovieIndex({ reader: await openNodeReader(enPath) }).open() },
  { language: "es", index: await new MovieIndex({ reader: await openNodeReader(esPath) }).open() },
];

/// The map `Scripts/fetch-wiki-groups.mjs` writes for one language, by hand: the forward array as
/// (stableId, group) sorted by stable id, the reverse as (group, rowIndex) sorted by group.
function groupsFor(forward, reverse) {
  const rows = [...forward].sort((a, b) => a[0] - b[0]);
  const groups = [...reverse].sort((a, b) => a[0] - b[0]);
  const bytes = Buffer.alloc(20 + rows.length * 8 + groups.length * 8);
  bytes.write("TCWG0002", 0, "utf8");
  bytes.writeUInt32LE(3, 8);
  bytes.writeUInt32LE(rows.length, 12);
  bytes.writeUInt32LE(groups.length, 16);
  let at = 20;
  for (const [stableId, groupId] of rows) {
    bytes.writeUInt32LE(stableId, at);
    bytes.writeUInt32LE(groupId, at + 4);
    at += 8;
  }
  for (const [groupId, rowIndex] of groups) {
    bytes.writeUInt32LE(groupId, at);
    bytes.writeUInt32LE(rowIndex, at + 4);
    at += 8;
  }
  return openGroups(bytes);
}

const languageGroups = new Map([
  ["en", groupsFor([[1000000, 7]], [[7, 0]])], // 500000 * 2, the English row at base position 0
  ["es", groupsFor([[800000, 7]], [[7, 1]])], // 400000 * 2, "Nueva York" at base position 1
]);

// The English row as the search hands it back after arriving in a delta: `row` is its position in that
// delta (3), which is not where the base row sits — and no longer what the map is keyed by.
const rows = [{
  id: "movie:500000",
  row: 3,
  tmdbID: 500000,
  mediaType: "movie",
  title: "New York City",
  originalTitle: "en.wikipedia.org",
  voteCount: 10,
  score: 90,
}];

check("the reverse column names a base row position, not the stable id",
  languageGroups.get("es").rowOfGroup(7) === 1, String(languageGroups.get("es").rowOfGroup(7)));

const merged = await mergeLanguages(rows, 5, languageGroups, bands);

check("a delta row is grouped by its stable id, not by its position",
  merged.length === 1 && merged[0].titles.en === "New York City" && merged[0].titles.es === "Nueva York",
  JSON.stringify(merged[0]?.titles));
check("the sibling is offered as an action",
  merged[0]?.actions.some((action) => action.id === "open:es"), JSON.stringify(merged[0]?.actions));
check("the subtitle names both wikis", merged[0]?.subtitle === "English · Español",
  String(merged[0]?.subtitle));

// Outside the map — an entity the map does not know — rows still group on an identical title.
const unmapped = await mergeLanguages(
  [{ ...rows[0], title: "Shared" },
    { ...rows[0], id: "movie:400001", tmdbID: 400001, row: 1, title: "Shared", originalTitle: "es.wikipedia.org" }],
  5, new Map(), bands);
check("an unmapped pair still merges on an identical title",
  unmapped.length === 1 && unmapped[0].titles.es === "Shared", JSON.stringify(unmapped[0]?.titles));

console.log(`\n${pass} passed, ${fail} failed`);
rmSync(dir, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
