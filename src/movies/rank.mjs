// Movie-specific reranker. Tinycast owns final cross-source ranking (SearchRelevance + frecency);
// this chooses order WITHIN the extension's ~10 provided results, so field strength here only needs
// to be internally consistent, not comparable to native entries.

import { foldTitle, normalizeTerms } from "./normalize.mjs";

// Signal tiers, high to low. The absolute scale is arbitrary; what matters is that a title hit beats
// an original-title hit beats a year/popularity tie-break.
const TIER = {
  EXACT_TITLE: 1 << 20,
  TITLE_PREFIX: 1 << 18,
  TOKEN_PREFIX: 1 << 16,
  TOKEN_SUBSTRING: 1 << 14,
  SUBSEQUENCE: 1 << 12,
  ORIGINAL_EXACT: 1 << 10,
  ORIGINAL_PREFIX: 1 << 9,
  ORIGINAL_WORD: 1 << 8,
  YEAR_MATCH: 1 << 5,
  POPULARITY_TIE: 1 << 4,
};

/// Score one movie (with its decoded title/original and folded forms) against a folded query.
/// Returns a single comparable number; higher is better.
export function movieScore({ title, originalTitle, year, voteCount }, queryTerms) {
  // A trailing four-digit token can scope a title search to its release year. Keep that token in
  // candidate retrieval and year scoring, but don't require it to appear in the title itself.
  // A lone number stays a title query (e.g. the film "1917").
  const titleTerms = queryTerms.length > 1
    ? queryTerms.filter((term) => !/^\d{4}$/.test(term))
    : queryTerms;
  const titleQuery = titleTerms.join(" ");
  const titleFolded = foldTitle(title);
  let score = 0;

  if (titleTerms.length === 1) {
    const q = titleTerms[0];
    if (titleFolded === q) score += TIER.EXACT_TITLE;
    if (starts(titleFolded, q)) score += TIER.TITLE_PREFIX;
    if (tokenPrefix(titleFolded.split(" "), q, titleFolded)) score += TIER.TOKEN_PREFIX;
    if (tokenSubstring(titleFolded, q)) score += TIER.TOKEN_SUBSTRING;
    if (q.length >= 3 && isSubsequence(q, titleFolded)) score += TIER.SUBSEQUENCE;

    const origFolded = originalTitle ? foldTitle(originalTitle) : "";
    if (origFolded && origFolded !== titleFolded) {
      if (origFolded === q) score += TIER.ORIGINAL_EXACT;
      else if (starts(origFolded, q)) score += TIER.ORIGINAL_PREFIX;
      else if (origFolded.split(" ").some((w) => starts(w, q))) score += TIER.ORIGINAL_WORD;
    }
  } else if (titleTerms.length > 1) {
    // multi-word: title matches on the whole folded title as one unit (prefix or full), plus a
    // bonus if the full query is a substring of the title.
    if (titleFolded === titleQuery) score += TIER.EXACT_TITLE;
    if (starts(titleFolded, titleQuery)) score += TIER.TITLE_PREFIX;
    if (titleQuery.length >= 4 && titleFolded.includes(titleQuery)) score += TIER.TOKEN_SUBSTRING;
    const origFolded = originalTitle ? foldTitle(originalTitle) : "";
    if (origFolded && origFolded === queryFolded && origFolded !== titleFolded) {
      score += TIER.ORIGINAL_EXACT;
    }
  }

  // Year match: 4-digit query term (e.g. "matrix 1999").
  for (const term of queryTerms) {
    if (term.length === 4 && /^\d{4}$/.test(term) && Number(term) === year) {
      score += TIER.YEAR_MATCH;
      break;
    }
  }

  // Within-tier tie-break: recency dominates for films released in the last ~5 years (so a brand-new
  // release like The Odyssey 2026 surfaces with zero votes), then vote count decides everywhere else.
  // Both are capped together just under the smallest tier gap (3072), so neither can cross a weaker
  // textual tier — an exact or strong title match always wins however new or well-voted a rival is.
  score += withinTier(year, voteCount);

  return score;
}


// The shared within-tier budget: recency (last 5 years) + vote count, capped just under the tier gap.
function withinTier(year, voteCount) {
  const recency = recencyBonus(year);
  const votes = voteBonus(voteCount);
  // Recency outranks well-voted older films while its window is active; otherwise votes decide.
  return Math.min(3071, recency + votes);
}

// 2026 release -> ~3000, decaying to 0 five years out, so only the last few years carry novelty.
function recencyBonus(year) {
  if (!(year > 0)) return 0;
  const currentYear = new Date().getFullYear();
  const yearsAgo = Math.max(0, currentYear - year);
  if (yearsAgo > 5) return 0;
  return Math.round(3000 * (1 - yearsAgo / 5));
}

// Vote count is a robust popularity proxy (TMDB's `popularity` is an opaque, gameable score). Log
// scaled so a widely-voted film separates from an unknown without a flat "most votes wins".
function voteBonus(voteCount) {
  if (!(voteCount > 0)) return 0;
  return Math.min(2500, Math.log(1 + voteCount) * 260);
}

function starts(s, prefix) {
  return prefix.length > 0 && s.length >= prefix.length && s.slice(0, prefix.length) === prefix;
}

function tokenPrefix(words, q, titleFolded) {
  if (!q) return false;
  return words.some((w) => w !== titleFolded && starts(w, q));
}

function tokenSubstring(titleFolded, q) {
  if (q.length < 2) return false;
  return titleFolded.split(" ").some((w) => w !== q && w.includes(q));
}

/// Strict subsequence (preserves order): e.g. "mlhld" -> "mulholland".
function isSubsequence(needle, haystack) {
  let i = 0;
  for (let j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack[j] === needle[i]) i++;
  }
  return i === needle.length;
}
