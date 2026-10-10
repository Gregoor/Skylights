// The provider's runtime-independent core: keep the cached index set in step with the release, open
// it, and turn a query into root-search candidates.
//
// The extension runtime supplies the fs shim and a downloader; tests supply node equivalents. Keeping
// this free of `@tinycast/api` is what lets the delivery glue be verified outside the app.

import { installedPaths, syncIndexes } from "../db/index-sync.mjs";
import { openRuntimeReader } from "../../src/db/runtime-reader.mjs";
import { MovieIndex } from "../../src/db/loader.mjs";
import { searchMovies } from "../../src/movies/search.mjs";
import { foldTitle } from "../../src/movies/normalize.mjs";

/// Which scores a row shows, per media type, in the order given — plus a fallback list used only
/// when the media type's own list has nothing for that title, so a title only IMDb has rated still
/// shows a number rather than nothing.
///
/// Rotten Tomatoes leads for both, with IMDb behind it, because that is what the data supports: OMDb
/// carries no Metacritic for series at all (12 of 84,558 enriched shows have one, where Metacritic
/// scores Succession, The Bear and Chernobyl alike), and its RT/Metacritic for films reach only ~5% of
/// what we hold — the prominent few thousand. IMDb is the one rating available for essentially every
/// record. Metacritic remains available; this is a default, not a limit.
///
/// A provider cannot read Tinycast's preferences yet, so this comes from a config file in the
/// provider's own cache — any combination, in any order:
///   { "ratings": { "movie": ["rt","metacritic"], "tv": ["rt"], "fallback": ["imdb"] } }
/// Values are "rt", "metacritic" and "imdb"; an empty list shows no score.
const DEFAULT_RATINGS = { movie: ["rt"], tv: ["rt"], fallback: ["imdb"] };

function readRatingsPreference(fs, cacheDir, log) {
  const path = `${cacheDir}/config.json`;
  try {
    if (!fs.existsSync(path)) return DEFAULT_RATINGS;
    const parsed = JSON.parse(fs.readFileSync(path, "utf8"))?.ratings ?? {};
    const asList = (value) => (value == null ? undefined : Array.isArray(value) ? value : [value]);
    return {
      movie: asList(parsed.movie) ?? DEFAULT_RATINGS.movie,
      tv: asList(parsed.tv) ?? DEFAULT_RATINGS.tv,
      fallback: asList(parsed.fallback) ?? DEFAULT_RATINGS.fallback,
    };
  } catch (error) {
    log(`config.json unreadable (${error?.message ?? error}) — using the defaults`);
    return DEFAULT_RATINGS;
  }
}

/// A row's subtitle is one uniformly-styled string, so the band rides on the glyph: RT is two-state
/// at its own 60% cutoff, Metacritic three-state at its own 61/40 thresholds.
function scoreText(source, value) {
  if (value == null) return "";
  if (source === "rt") return `${value >= 60 ? "\u{1F345}" : "\u{1F4A5}"} ${value}%`;
  if (source === "metacritic") {
    return `${value >= 61 ? "\u{1F7E2}" : value >= 40 ? "\u{1F7E1}" : "\u{1F534}"} ${value}`;
  }
  if (source === "imdb") return `\u{2B50} ${(value / 10).toFixed(1)}`;
  return "";
}

/// The chosen scores for a row, in the configured order, skipping sources with no score for it.
function ratingTexts(movie, ratings) {
  const primary = scoreTexts(movie, ratings[movie.mediaType] ?? []);
  return primary.length > 0 ? primary : scoreTexts(movie, ratings.fallback ?? []);
}

function scoreTexts(movie, sources) {
  return sources
    .map((source) =>
      source === "rt" ? movie.rtScore
      : source === "metacritic" ? movie.metacriticScore
      : source === "imdb" ? movie.imdbRating
      : null)
    .map((value, i) => scoreText(sources[i], value))
    .filter((text) => text !== "");
}

/// How long an open index set is trusted before the manifest is checked again. The provider session
/// is resident for the app's lifetime, so without this a launch would never see a later delta — and
/// re-checking per keystroke would hit the network on every query.
const REFRESH_MS = 6 * 60 * 60 * 1000;

/// `manifestURL` + `cacheDir` locate the release and the local cache; `fs` + `download` are the
/// injected runtime facilities. The returned `search` never throws — an unavailable index answers
/// nothing, and a failed refresh falls back to the set already open, so a resident provider session
/// can't be broken by a failed download.
export function createProviderCore({
  manifestURL, cacheDir, fs, download, gunzip, log = () => {}, now = Date.now, refreshMs = REFRESH_MS,
}) {
  let indexes = null;
  let ratings = null;
  let openPaths = "";
  let syncedAt = 0;
  let opening = null;

  async function ensureIndexes() {
    if (indexes && now() - syncedAt < refreshMs) return indexes;
    if (!opening) {
      opening = (async () => {
        // Read the display config before the sync, so a pruning bug in the sync can never eat it.
        ratings ??= readRatingsPreference(fs, cacheDir, log);
        // Open what is installed before asking whether anything newer exists. A cache that is merely due
        // a check holds a valid index, and opening it here is what lets a failed sync leave it serving:
        // a manifest naming an asset the release does not have must not turn into an empty launcher.
        // Try the installed set first so a network failure can still serve it. It may be corrupt or
        // from an older index format, though; that must not prevent the manifest sync below from
        // replacing it. In particular, opening an old format throws before syncIndexes gets a chance
        // to notice the format change and download the current base.
        const cachedPaths = installedPaths({ cacheDir, fs, maxAgeMs: Infinity, now });
        if (cachedPaths) {
          try {
            indexes = await openPathsFor(cachedPaths);
          } catch (error) {
            log(`installed tmdb index could not be opened; refreshing it: ${error?.message ?? error}`);
          }
        }
        // A valid cache checked within the refresh window mounts straight from disk; anything else
        // checks the manifest, which is a network round trip and no longer holds a query, since the
        // transfer yields.
        if (indexes && installedPaths({ cacheDir, fs, maxAgeMs: refreshMs, now })) return indexes;
        try {
          indexes =
            await openPathsFor(await syncIndexes({ manifestURL, cacheDir, fs, download, gunzip, log, now }));
        } catch (error) {
          log(`tmdb index refresh failed, serving what is installed: ${error?.message ?? error}`);
        }
        return indexes;
      })();
      opening
        .then((list) => {
          indexes = list;
          syncedAt = now();
        })
        .catch(() => {})
        .finally(() => {
          opening = null;
        });
    }
    return opening;
  }

  /// The indexes a path list names, or the open set when there is nothing to open. Re-opens only when
  /// the set changed, because opening an index reads hundreds of megabytes.
  async function openPathsFor(paths) {
    if (!paths || paths.length === 0) return indexes;
    const key = paths.join("|");
    if (key === openPaths && indexes) return indexes;
    const list = [];
    for (const path of paths) {
      list.push(await new MovieIndex({ reader: openRuntimeReader(path, fs) }).open());
    }
    openPaths = key;
    return list;
  }

  async function search(query, limit) {
    let list;
    try {
      list = await ensureIndexes();
    } catch (error) {
      log(`tmdb index unavailable: ${error?.message ?? error}`);
      list = indexes; // serve the last good set rather than nothing
    }
    if (!list) return [];
    const results = await searchMovies(list, query, { limit });
    // Normalized to the top row of this result set, so the app can rank these among its own rows
    // instead of appending them. Provider-relative by design: two providers' scales never compare.
    const top = results[0]?.score ?? 0;
    return results.map((movie) => toCandidate(movie, ratings, top));
  }

  return { search, ensureIndexes };
}

function toCandidate(movie, ratings, topScore = 0) {
  const original = movie.originalTitle;
  // A row leads with whichever title the query matched and dims the other behind it, so what matched
  // is visible either way round. Folded-equal titles ("Marter" / "MARTER") are the same title and dim
  // nothing, which keeps English-language results showing the year alone.
  const leads = Boolean(movie.matchedOriginal && original);
  const name = leads ? original : movie.title;
  const alternate = leads ? movie.title : original;
  const differs = Boolean(alternate) && foldTitle(alternate) !== foldTitle(name);
  const parts = [];
  if (differs) parts.push(alternate);
  if (movie.year != null) parts.push(String(movie.year));
  if (movie.mediaType === "tv" && movie.seasonCount > 0) parts.push(`${movie.seasonCount} seasons`);
  parts.push(...ratingTexts(movie, ratings));
  return {
    // The id carries the media type so activation can route to the right popfeed path.
    id: `${movie.mediaType}:${movie.tmdbID}`,
    title: name,
    subtitle: parts.join(" · ") || undefined,
    // Whichever title isn't the row's name stays searchable.
    keywords: differs ? [alternate] : [],
    posterURL: movie.posterURL ?? undefined,
    label: movie.mediaType === "tv" ? "TV Show" : "Movie",
    score: topScore > 0 ? movie.score / topScore : undefined,
  };
}

/// Activation target: the popfeed page for a record, routed by the id's media type.
export function activationURL(resultId) {
  const [kind, tmdbID] = String(resultId ?? "").split(":");
  if (!tmdbID) return null;
  return `https://popfeed.social/${kind === "tv" ? "tv_show" : "movie"}/${tmdbID}`;
}
