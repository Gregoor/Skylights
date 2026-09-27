// The Tinycast root-search provider for Wikipedia: English, German and Spanish.
//
// The artifact contract is the movie provider's — a hash-verified index in the cache the host hands
// over, synced from a manifest, searched through the shared loader and ranker — so this file is the
// whole difference between the two. What it does not reuse: the ratings preference (Wikipedia rows
// have no scores) and `provider-core`, which composes movie-specific subtitles.
//
// One index per language, each with its own cache directory and manifest. That keeps a language's band
// its own decision — English can be 100 MB while Spanish is 20 — and it is what the index format
// needs anyway: a row's media-type bit is one bit, so the language cannot live inside it. The search
// already merges a list of indexes, which is how base + deltas work.
//
// The manifests are local while this is a prototype. `syncIndexes` cannot tell the difference — it
// fetches a URL, checks a hash, and installs — so pointing these at release assets is a one-line change
// once there are any.

import { registerRootSearchProvider, open } from "@tinycast/api";
import { download, gunzip } from "../transfer.mjs";
import { installedPaths, syncIndexes } from "../db/index-sync.mjs";
import { openRuntimeReader } from "../db/runtime-reader.mjs";
import { MovieIndex } from "../db/loader.mjs";
import { searchMovies } from "../movies/search.mjs";
import { openGroups } from "./groups.mjs";

/// In preference order: English breaks a tie between equally good matches, and the rest are offered in
/// this order. Raycast treats the first action of a list as the default, so ↵ opens whichever wiki the
/// query itself matched best.
const LANGUAGES = ["en", "de", "es"];
const LANGUAGE_NAMES = { en: "English", de: "German", es: "Spanish" };
/// The language in its own words, which is what a row's subtitle shows — the convention Wikipedia's own
/// language list follows, so a Spanish reader sees "Español" rather than "es.wikipedia.org".
const LANGUAGE_LABELS = { en: "English", de: "Deutsch", es: "Español" };

/// The rolling release. `releases/latest/download/<name>` is where the movie index's manifest already
/// lives, so both providers share one release rather than racing for the URL that `latest` resolves to.
const MANIFEST_BASE = "https://github.com/Gregoor/tinycast-tmdb/releases/latest/download";

const REFRESH_MS = 6 * 60 * 60 * 1000;

const CACHE_DIR = process.env.TINYCAST_PROVIDER_CACHE;
if (!CACHE_DIR) {
  throw new Error("TINYCAST_PROVIDER_CACHE is unset — the host must say where the index belongs");
}

/// Which wiki a row came from. The label the records carry is `<lang>.wikipedia.org`, in the slot the
/// index already has for a subtitle.
const languageOf = (row) => String(row.originalTitle ?? "").split(".")[0] || "en";

/// The stable id the cross-language map is keyed by, for a row the search handed back. A wiki row is
/// always a movie, so the media-type bit is 0 and the key is the article id doubled — the same value
/// the index records, which is what lets a delta's row be found in a map built from the base.
const stableIdOf = (row) => MovieIndex.stableKey(row.mediaType === "tv" ? 1 : 0, row.tmdbID);

/// The row offered when the band has nothing. The band is a byte-budgeted slice of three wikis, so an
/// article below its floor is *absent* rather than missing — and the honest answer to that is the wikis'
/// own search page, which is also what a fallback command would open. Each wiki gets an action because
/// nothing matched, so nothing can say which one the reader wants.
function searchRow(query) {
  return {
    id: `search:${query}`,
    title: `Search Wikipedia for "${query}"`,
    subtitle: "Not in the offline index",
    keywords: [],
    label: "Wikipedia",
    iconPath: "wikipedia.png",
    actions: [
      { id: "search:en", title: "Search in English", shortcut: "↵" },
      { id: "search:de", title: "Search in German" },
      { id: "search:es", title: "Search in Spanish" },
    ],
  };
}

/// One row per entity, with every wiki that carries it offered as actions.
///
/// Entities come from the shipped cross-language map where it knows them, so a counterpart no longer
/// has to be spelled the same way: "New York City", "Nueva York" and "New York City" are one row.
/// Outside the map — only its head is mapped — the title still groups rows: identical titles across
/// languages are the same entity far more often than not, and a title that differs is left alone rather
/// than guessed at, because a wrong merge hides a result.
///
/// The row keeps the language whose match scored best, so a German query shows the German title it
/// matched rather than the English one; English breaks a tie. A sibling the query never matched is read
/// back from its own index, since its title is only ever known there.
export async function mergeLanguages(rows, limit, languageGroups, bands) {
  const startsCapitalised = (title) => title === title.charAt(0).toUpperCase() + title.slice(1);
  /// The better of two rows for one wiki: the query's own score first, then how read the article is —
  /// and on a tie the capitalised title, which is the article rather than the redirect pointing at it.
  const better = (candidate, incumbent) => {
    const match = (candidate.score ?? 0) - (incumbent.score ?? 0);
    if (match !== 0) return match > 0;
    const difference = (candidate.voteCount ?? 0) - (incumbent.voteCount ?? 0);
    if (difference !== 0) return difference > 0;
    return startsCapitalised(candidate.title) && !startsCapitalised(incumbent.title);
  };

  const groups = new Map();
  /// Which group already holds a title, so a row the map does not know — a redirect spelling, or one
  /// outside the map's head — still merges with the article it duplicates.
  const byTitle = new Map();
  for (const row of rows) {
    const language = languageOf(row);
    // A mapped entity joins every language's row for it. The map is keyed by stable id, not by the
    // row's position — which for a delta's row is a different position than the base's. Wikipedia
    // capitalises the first letter of every article title, so an unmapped lowercase variant is a
    // redirect to the same page and folds into the same key as its capitalised twin.
    const entity = languageGroups.get(language)?.groupOfRow(stableIdOf(row)) ?? 0;
    const folded = row.title.toLowerCase();
    const key = entity ? `entity:${entity}` : (byTitle.get(folded) ?? `title:${folded}`);
    const group = groups.get(key) ?? { byLanguage: new Map(), best: row, entity };
    const held = group.byLanguage.get(language);
    if (!held || better(row, held)) group.byLanguage.set(language, row);
    if (better(row, group.best)) group.best = row;
    groups.set(key, group);
    byTitle.set(folded, key);
  }

  const merged = [];
  for (const group of groups.values()) {
    const primary = group.best;
    const primaryLanguage = languageOf(primary);
    const titles = {};
    for (const [language, row] of group.byLanguage) titles[language] = row.title;
    // Siblings the query never matched: the map knows which row, only the index knows its title.
    for (const language of LANGUAGES) {
      if (titles[language] || !group.entity) continue;
      const at = languageGroups.get(language)?.rowOfGroup(group.entity);
      const band = bands.find((entry) => entry.language === language);
      if (at == null || !band) continue;
      titles[language] = await titleOfRow(band.index, at);
    }
    const languages = LANGUAGES.filter((language) => titles[language]);
    const label = (language) => LANGUAGE_LABELS[language] ?? language;
    merged.push({
      row: primary,
      titles,
      // The provider's own order: how well the match read, then how read the article is.
      score: Math.max(...[...group.byLanguage.values()].map((row) => row.score ?? 0)),
      // One list, with no section break: the other wikis are alternatives to the same article rather
      // than more results, and a separator made them read as a second group of rows.
      actions: [
        { id: `open:${primaryLanguage}`, title: "Open Article", shortcut: "↵" },
        ...languages
          .filter((language) => language !== primaryLanguage)
          .map((language) => ({
            id: `open:${language}`,
            title: `Open in ${LANGUAGE_NAMES[language] ?? language}`,
          })),
      ],
      // Every wiki the row offers, by name, the one ↵ opens first: the palette has the room, and a
      // reader can see the Spanish article is there before opening the menu to find it.
      subtitle: [primaryLanguage, ...languages.filter((language) => language !== primaryLanguage)]
        .map(label)
        .join(" · "),
    });
  }

  return merged.sort((a, b) => b.score - a.score).slice(0, limit);
}

/// A row's own title, read from the index that holds it.
async function titleOfRow(index, rowIndex) {
  const [rec] = await index.readRows([rowIndex]);
  const { titles } = await index.readTitles([rec]);
  return titles[0];
}

export default function command() {
  const fs = require("fs");
  /// The mounted bands and the cross-language map beside each — one object, replaced as a whole — and
  /// the mount in flight, if any.
  let mounted = null;
  let mounting = null;
  let syncedAt = 0;
  /// A search only returns an id, so activation needs what the row was built from: the article title
  /// and the wiki it lives on. Kept for the session rather than encoded into the id, which the shared
  /// search composes from the record's own id.
  const articles = new Map();

  /// Open one wiki from whatever is installed — even a stale copy, which answers a query far better
  /// than nothing does while a sync runs. That wiki's bands are replaced rather than added to, so a copy
  /// a sync superseded cannot stay searched beside the one that replaced it.
  async function install(language, corpus) {
    const cacheDir = `${CACHE_DIR}/${language}`;
    const paths = installedPaths({ cacheDir, fs, maxAgeMs: Infinity });
    if (!paths) return false;
    // A manifest carries the base index, whatever deltas are still in its chain, and the cross-language
    // map beside them. The loader merges a list by stable key, keeping the newest version of each, so
    // they are all opened — in the order the manifest names them, base first.
    const indexes = paths.filter((path) => path.endsWith(".index"));
    if (indexes.length === 0) return false;
    const opened = [];
    for (const path of indexes) {
      opened.push(await new MovieIndex({ reader: openRuntimeReader(path, fs) }).open());
    }
    for (let at = corpus.bands.length - 1; at >= 0; at -= 1) {
      if (corpus.bands[at].language === language) corpus.bands.splice(at, 1);
    }
    for (const index of opened) corpus.bands.push({ language, index });
    const groupsPath = paths.find((path) => path.endsWith(".groups"));
    const groups = groupsPath ? openGroups(fs.readFileSync(groupsPath)) : null;
    if (groups) corpus.languageGroups.set(language, groups);
    return true;
  }

  /// Mount every wiki. What is already on disk comes first, published as soon as the first wiki is up,
  /// so a query arriving during a mount is answered instead of left cold. The syncs then run one wiki at
  /// a time behind those queries, each replacing its own bands as it lands — and a sync that fails leaves
  /// the copy already serving.
  async function mount() {
    const corpus = { bands: [], languageGroups: new Map() };
    for (const language of LANGUAGES) {
      if ((await install(language, corpus)) && !mounted) mounted = corpus;
    }
    for (const language of LANGUAGES) {
      const cacheDir = `${CACHE_DIR}/${language}`;
      // A cache checked within REFRESH_MS mounts straight from disk; anything else syncs first, which no
      // longer holds a query because the transfer yields.
      if (installedPaths({ cacheDir, fs, maxAgeMs: REFRESH_MS })) continue;
      try {
        await syncIndexes({
          manifestURL: `${MANIFEST_BASE}/wikipedia-${language}-manifest.json`,
          cacheDir,
          fs,
          download,
          gunzip,
        });
      } catch {
        continue;
      }
      await install(language, corpus);
    }
    return corpus;
  }

  function ensureIndexes() {
    if (!mounted || Date.now() - syncedAt >= REFRESH_MS) startMount();
    return mounted;
  }

  function startMount() {
    if (mounting) return;
    mounting = mount()
      .then((corpus) => {
        mounted = corpus;
        syncedAt = Date.now();
      })
      // A failed mount leaves nothing mounted, and the next query starts another.
      .catch(() => {})
      .finally(() => {
        mounting = null;
      });
  }

  registerRootSearchProvider({
    id: "wikipedia",
    // Below the movie provider's 2, deliberately: an article whose title is also a film's is the
    // fallback rather than the answer. Still above 0, so a wiki row outranks a provider that declares
    // no precedence at all — where a query ties across providers, a declared one is the deliberate
    // answer and an undeclared one is not.
    precedence: 1,
    async search(query, { limit }) {
      const corpus = ensureIndexes();
      // Nothing mounted yet: answer nothing rather than waiting for it. The mount it just started
      // serves the next query, which is what keeps a first-query mount out of the p99.
      if (!corpus) return [];
      const { bands, languageGroups } = corpus;
      // Ask for enough that every row's siblings are in the pool: a merge can only offer a language it
      // has already been handed.
      const pool = Math.max(limit * LANGUAGES.length * 2, 25);
      const rows = await searchMovies(
        bands.map((band) => band.index), query, { limit: pool, candidatePool: pool });
      const merged = await mergeLanguages(rows, limit, languageGroups, bands);
      if (merged.length === 0) return [searchRow(query)];
      // `merged` is already the provider's own order — how well the title reads as a match, then how
      // read the article is. Normalized to 0…1 so Tinycast can rank these among its own rows instead
      // of appending them; the app never compares two providers' scales, only one provider's rows.
      const top = merged[0]?.score ?? 0;
      return merged.map(({ row, titles, actions, subtitle, score }) => {
        // Activation needs the title this row shows on every wiki it offers: a counterpart article is
        // very often spelled differently, and the action id names which wiki to open.
        articles.set(row.id, { titles, language: languageOf(row) });
        return {
          id: row.id,
          title: row.title,
          subtitle,
          keywords: [],
          actions,
          label: "Wikipedia",
          // The mark beside the bundle, which the host resolves inside the provider's own directory.
          iconPath: "wikipedia.png",
          score: top > 0 ? score / top : undefined,
        };
      });
    },
    async perform(resultID, actionID) {
      // A search row is not an article: the action names the wiki to search in and the id carries the
      // query, so no session state is involved and it works even if the corpus was released.
      if (String(resultID).startsWith("search:")) {
        const language = String(actionID ?? "search:en").slice("search:".length);
        if (!LANGUAGES.includes(language)) return;
        const query = String(resultID).slice("search:".length);
        await open(
          `https://${language}.wikipedia.org/w/index.php?search=${encodeURIComponent(query)}`,
          "Safari");
        return;
      }
      const language = actionID ? actionID.slice("open:".length) : null;
      const article = articles.get(resultID);
      if (!article) return;
      // The action names a wiki, and that wiki's own spelling is the one to open.
      const target = article.titles[language] ? language : article.language;
      const title = article.titles[target];
      if (!title) return;
      await open(
        `https://${target}.wikipedia.org/wiki/${encodeURIComponent(title.replaceAll(" ", "_"))}`,
        "Safari");
    },
  });

  // The host starts this session as the palette opens, so the mount begins then rather than at the first
  // keystroke: the first query has rows, and the palette holds the index until it closes.
  startMount();

  // Keep the resident session mounted: never settle.
  return new Promise(() => {});
}
