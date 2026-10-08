// What the published index contains.
//
// The store stays complete, but the index is what clients download and hold resident. Keep titles
// with some audience or professional coverage: at least five TMDB votes, or an RT, Metacritic,
// or IMDb score. Also keep releases from last year onward so new and upcoming titles can appear
// before votes or ratings arrive.
// Weekly base rebuilds and daily deltas both apply this rule.
export const MIN_VOTES = 5;
export const RECENT_YEARS = 2;

/// Whether a record belongs in the published index.
export function inBand(record, { year = new Date().getFullYear() } = {}) {
  const votes = record?.voteCount ?? 0;
  return votes >= MIN_VOTES || record?.rtScore != null || record?.metacriticScore != null ||
    record?.imdbRating != null || (record?.year ?? 0) >= year - (RECENT_YEARS - 1);
}

/// Kept/dropped counts, for the builders to report what they left out.
export function bandCounts(records, options) {
  let kept = 0;
  for (const record of records) if (inBand(record, options)) kept++;
  return { kept, dropped: records.length - kept };
}
