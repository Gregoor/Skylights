// Ranking + candidate-retrieval correctness against an index (partial or full).
//
//   node test/rank.test.mjs [index.path]
//
// The plan's launcher-semantics cases (docs §23): exact title first, prefix, original-title,
// diacritics, year-aware multi-word queries, no-result, and a brute-force "no-miss" check that
// candidate retrieval returns every word-prefix/exact match a linear scan would find.
//
// The famous-title cases are asserted only when that title is present in the index, so this runs
// against a partial store during the backfill and asserts fully against the complete one.

import { openNodeReader } from "../src/db/loaders.mjs";
import { MovieIndex } from "../src/db/loader.mjs";
import { searchMovies } from "../src/movies/search.mjs";
import { normalizeTerms } from "../src/movies/normalize.mjs";

const indexPath = process.argv[2] ?? "build/tmdb.index";
let pass = 0;
let skipped = 0;
let fail = 0;
function check(label, cond, extra = "") {
  if (cond) { pass++; }
  else { fail++; console.log(`  FAIL ${label}${extra ? ` — ${extra}` : ""}`); }
}

const reader = await openNodeReader(indexPath);
const index = new MovieIndex({ reader });
await index.open();
console.log(`index: ${index.rowCount} rows, ${index.termCount} terms, ${index.postings.length} postings`);

const titles = async (q, n = 5) => (await searchMovies(index, q, { limit: n })).map((x) => `${x.title} (${x.year})`);

/// Assert `expected` ranks first for `query`, or skip when the title isn't in this index at all.
async function expectFirst(query, expected) {
  const found = await titles(expected, 3);
  if (!found.some((t) => t.startsWith(expected))) {
    skipped++;
    return;
  }
  const top = await titles(query, 3);
  check(`'${query}' → ${expected} first`, top[0]?.startsWith(expected), top.join(" | "));
}

// ── ranking semantics (asserted when the title is present; skipped on a partial index) ───────────
await expectFirst("alien", "Alien (1979)");
await expectFirst("mulholl", "Mulholland Drive (2001)");
await expectFirst("matrix 1999", "The Matrix (1999)");
await expectFirst("war 2026", "War (2026)"); // year narrows candidates; exact title still wins
await expectFirst("interstellar", "Interstellar (2014)");
await expectFirst("amelie", "Amélie (2001)"); // diacritic fold
// Three or more terms exercise every required-term check; a `continue` aimed at the wrong loop once
// made every such query return nothing at all.
await expectFirst("city of god", "City of God (2002)");
// Several films share this exact title, so assert the title rather than one year's entry.
await expectFirst("war of the worlds", "War of the Worlds");
await expectFirst("the silence of the lambs", "The Silence of the Lambs (1991)");
// Non-Latin originals: folding used to treat every code point above U+0300 as a combining mark, so
// a Japanese or Cyrillic title folded to nothing and was unsearchable however it was typed.
await expectFirst("千と千尋", "Spirited Away (2001)");
await expectFirst("Ночной дозор", "Night Watch (2004)");
await expectFirst("Дневной дозор", "Day Watch (2006)");
// A wide prefix must not be checked before a rare term. "s" spans ~43k index terms, and consulting
// it first made this query scan the whole "where" range at ~43k binary searches per row (800 ms).
const wide = await titles("where's wanda", 5);
check("a wide prefix plus a rare term still finds the title",
  wide.some((t) => t.includes("Wanda")), wide.join(" | "));
check("unknown query → empty", (await titles("zzzzqqqqxx", 5)).length === 0);

// ── media type reaches the result (movie vs TV) ─────────────────────────────────────────────────
for (const q of ["matrix", "the wire", "arcane"]) {
  const res = await searchMovies(index, q, { limit: 3 });
  for (const r of res) {
    check(`'${q}' result carries a mediaType`, r.mediaType === "movie" || r.mediaType === "tv", r.mediaType);
    break;
  }
}

// ── no-miss: candidate retrieval is a superset of a brute-force word-prefix/exact scan ──────────
// A row is expected iff its last-term prefix postings contain it AND all required terms' postings
// contain it; collectCandidates must return a superset of that, capped only by `cap`.
{
  const probe = ["alien", "matrix", "mulholland", "dark", "knight", "parasite", "amelie", "interstellar", "inception", "the wire"];
  let misses = 0;
  for (const q of probe) {
    const qt = normalizeTerms(q);
    const got = new Set(index.collectCandidates(qt, 500000));
    let expected = new Set();
    const lastRange = index._termRange(qt[qt.length - 1]);
    if (lastRange) {
      for (let p = lastRange[0]; p < lastRange[1]; p++) expected.add(index.postings[p]);
      for (let t = 0; t < qt.length - 1; t++) {
        const r = index._termRange(qt[t]);
        if (!r) { expected = new Set(); break; }
        const members = new Set();
        for (let p = r[0]; p < r[1]; p++) members.add(index.postings[p]);
        expected = new Set([...expected].filter((row) => members.has(row)));
      }
    }
    const missing = [...expected].filter((row) => !got.has(row));
    if (missing.length > 0) {
      misses++;
      console.log(`  MISS for "${q}": ${missing.length} rows not retrieved`);
    }
  }
  check("no-miss: candidate retrieval superset of brute-force scan", misses === 0, `${misses} queries missed rows`);
}

await reader.close();
console.log(`\n${pass} passed, ${skipped} skipped, ${fail} failed`);
process.exit(fail ? 1 : 0);
