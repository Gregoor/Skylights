// What the published index contains.
//
// The store stays complete, but the index is what clients download and hold resident. Keep titles
// with some audience or professional coverage: at least five TMDB votes, or an RT, Metacritic,
// or IMDb score.
// Weekly base rebuilds and daily deltas both apply this rule.
export const MIN_VOTES = 5;

/// Whether a record belongs in the published index.
export function inBand(record) {
  const votes = record?.voteCount ?? 0;
  return votes >= MIN_VOTES || record?.rtScore != null || record?.metacriticScore != null ||
    record?.imdbRating != null;
}

/// Kept/dropped counts, for the builders to report what they left out.
export function bandCounts(records, options) {
  let kept = 0;
  for (const record of records) if (inBand(record, options)) kept++;
  return { kept, dropped: records.length - kept };
}
