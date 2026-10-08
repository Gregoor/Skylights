// The shared search entry point used by both the Raycast command and the Tinycast root provider.
// Keeps movie-specific logic out of the storage layer and out of the runtime bridge.
//
// Searches one OR MORE indexes (a base plus any deltas) and merges them: a delta supersedes the
// stable keys it carries, and the newest version of a key wins — so an edited title, a changed
// poster, or a removed record all resolve correctly without renumbering the base.

import { movieScore } from "./rank.mjs";
import { foldTitle, normalizeTerms } from "./normalize.mjs";
import { MovieIndex } from "../db/loader.mjs";

// Two-stage: inverted-index candidate retrieval (stage 1) then fine reranking (stage 2).
//
// `indexes` is a single index or an ordered list — base first, then deltas oldest→newest.
export async function searchMovies(indexes, query, { limit = 10, candidatePool = 25 } = {}) {
  const list = Array.isArray(indexes) ? indexes : [indexes];
  const queryTerms = normalizeTerms(query);
  if (queryTerms.length === 0) return [];
  const textQueryTerms = queryTerms.length > 1
    ? queryTerms.filter((term) => !/^\d{4}$/.test(term))
    : queryTerms;
  const hasYearFilter = textQueryTerms.length !== queryTerms.length;
  // Year-filtered queries tend to have many matching titles. A larger pool lets reranking find an
  // exact short title even when it appears late in the index's row order (for example, "War 2026").
  const poolSize = hasYearFilter ? Math.max(candidatePool, 256) : candidatePool;

  // Keys superseded by anything newer than index i are stale where they appear in i.
  const newerSuperseded = supersededAfter(list);

  // Collect scored entries from every index (stage 1 per index).
  const entries = [];
  for (let i = 0; i < list.length; i++) {
    const index = list[i];
    const candidates = index.collectCandidates(queryTerms, poolSize);
    if (candidates.length === 0) continue;
    const records = await index.readRows(candidates);
    const { titles, originals } = await index.readTitles(records);
    const posters = await index.readPosters(records);
    for (let k = 0; k < records.length; k++) {
      const rec = records[k];
      const key = MovieIndex.stableKeyOfRow(rec);
      // A base row this delta replaces is stale even if its own text still matched the query.
      if (newerSuperseded[i].has(key)) continue;
      const title = titles[k];
      const originalTitle = originals[k] || "";
      const titleFolded = foldTitle(title);
      const originalFolded = originalTitle ? foldTitle(originalTitle) : "";
      entries.push({
        key,
        index: i,
        rec,
        title,
        originalTitle,
        posterURL: posters[k] ? `https://image.tmdb.org/t/p/w92${posters[k]}` : null,
        score: movieScore(
          { title, originalTitle, year: rec.year, voteCount: rec.voteCount },
          queryTerms),
        // Nothing matched the display title but the original did, so a row showing the match should
        // lead with the original. Read off the text rather than the scorer's tiers: its multi-word
        // original tier only fires on an exact whole-string match, so a partial original match
        // ('mala educación' -> 'La mala educación') would otherwise go uncredited.
        matchedOriginal: Boolean(originalFolded) && originalFolded !== titleFolded &&
          textQueryTerms.length > 0 && matchesFolded(originalFolded, textQueryTerms) &&
          !matchesFolded(titleFolded, textQueryTerms),
      });
    }
  }

  // Dedupe by stable key, keeping the newest index's version, then rank (stage 2).
  const best = new Map();
  for (const entry of entries) {
    const seen = best.get(entry.key);
    if (!seen || entry.index >= seen.index) best.set(entry.key, entry);
  }

  return [...best.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(({ rec, title, originalTitle, posterURL, score, matchedOriginal }) => ({
      // Stable identity for frecency + activation: `<mediaType>:<tmdbID>`.
      id: `${rec.mediaType === 1 ? "tv" : "movie"}:${rec.tmdbID}`,
      tmdbID: rec.tmdbID,
      imdbID: rec.imdbNum ? `tt${String(rec.imdbNum).padStart(7, "0")}` : null,
      title,
      originalTitle: originalTitle || null,
      year: rec.year || null,
      seasonCount: rec.mediaType === 1 ? rec.seasonCount || 0 : null,
      voteCount: rec.voteCount,
      posterURL,
      mediaType: rec.mediaType === 1 ? "tv" : "movie",
      // True when the query matched the original title rather than the display title.
      matchedOriginal,
      // 0-100 each, or null when that source has no score for this title (255 on disk).
      rtScore: rec.rtScore === 255 ? null : rec.rtScore,
      metacriticScore: rec.metacriticScore === 255 ? null : rec.metacriticScore,
      imdbRating: rec.imdbRating === 255 ? null : rec.imdbRating,
      score,
    }));
}

/// Whether every query term appears in `folded`, as a token prefix or anywhere in the string.
function matchesFolded(folded, queryTerms) {
  if (!folded) return false;
  const words = folded.split(" ");
  return queryTerms.every((q) => words.some((w) => w.startsWith(q)) || folded.includes(q));
}

/// For each index, the set of stable keys superseded by any index AFTER it (base at 0).
function supersededAfter(list) {
  const after = new Array(list.length);
  let union = new Set();
  for (let i = list.length - 1; i >= 0; i--) {
    after[i] = new Set(union);
    for (const key of list[i].supersededKeys ?? []) union.add(key);
  }
  return after;
}
