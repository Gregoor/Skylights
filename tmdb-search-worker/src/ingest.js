const DAY_MS = 24 * 60 * 60 * 1000;
const TMDB = "https://api.themoviedb.org/3";
const OMDB = "https://www.omdbapi.com/";
const MDBLIST = "https://api.mdblist.com";
let nextTmdbRequestAt = 0;

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sqlText = (value) => "'" + String(value ?? "").replaceAll("'", "''") + "'";
const foldText = (value) => String(value ?? "").normalize("NFD").replace(/\p{M}+/gu, "")
  .toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
const score100 = (value) => {
  const parsed = Number.parseFloat(String(value ?? "").replace("%", ""));
  return Number.isFinite(parsed) ? Math.max(0, Math.min(100, Math.round(parsed))) : null;
};
const imdb100 = (value) => {
  const parsed = Number.parseFloat(String(value ?? ""));
  return Number.isFinite(parsed) ? Math.max(0, Math.min(100, Math.round(parsed * 10))) : null;
};

function todayUTC(now = new Date()) {
  return now.toISOString().slice(0, 10);
}

function latestTmdbExportDate(now = new Date()) {
  const exportDate = new Date(now);
  if (now.getUTCHours() < 9) exportDate.setUTCDate(exportDate.getUTCDate() - 1);
  return todayUTC(exportDate);
}

async function getState(db, key) {
  const row = await db.prepare("SELECT value FROM sync_state WHERE key = ?").bind(key).first();
  return row?.value ?? null;
}

async function setState(db, key, value) {
  await db.prepare(`INSERT INTO sync_state(key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value`).bind(key, String(value)).run();
}

async function stateNumber(db, key, day) {
  const raw = await getState(db, key);
  if (!raw) return 0;
  try {
    const parsed = JSON.parse(raw);
    return parsed.day === day ? Number(parsed.count) || 0 : 0;
  } catch {
    return 0;
  }
}

async function addDailyCount(db, key, day, amount) {
  const count = await stateNumber(db, key, day) + amount;
  await setState(db, key, JSON.stringify({ day, count }));
  return count;
}

async function streamGzipLines(response, onLine) {
  if (!response.ok || !response.body) throw new Error(`download failed: HTTP ${response.status}`);
  const reader = response.body.pipeThrough(new DecompressionStream("gzip")).getReader();
  const decoder = new TextDecoder();
  let carry = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    const lines = (carry + decoder.decode(value, { stream: true })).split("\n");
    carry = lines.pop() ?? "";
    for (const line of lines) if (line.trim()) await onLine(line);
  }
  carry += decoder.decode();
  if (carry.trim()) await onLine(carry);
}

async function writeStatementBatches(db, statements) {
  const groupSize = 100;
  for (let offset = 0; offset < statements.length; offset += groupSize) {
    await db.batch(statements.slice(offset, offset + groupSize).map((sql) => db.prepare(sql)));
  }
}

async function stageTmdbExport(env, date, kind, mediaType) {
  const url = `https://files.tmdb.org/p/exports/${kind}_${date.replaceAll("-", "_")}.json.gz`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`TMDB ${kind} export -> HTTP ${response.status}`);
  const sqlBatch = [];
  let rows = [];
  let count = 0;
  const flush = async () => {
    if (!rows.length) return;
    sqlBatch.push(`INSERT INTO tmdb_daily_ids(export_date, media_type, id, original_title, original_title_folded) VALUES ${rows.join(",")}
      ON CONFLICT(export_date, media_type, id) DO UPDATE SET original_title=excluded.original_title,
        original_title_folded=excluded.original_title_folded;`);
    rows = [];
    if (sqlBatch.length >= 100) {
      await writeStatementBatches(env.DB, sqlBatch.splice(0));
    }
  };
  await streamGzipLines(response, async (line) => {
    const entry = JSON.parse(line);
    const id = Number(entry.id);
    if (!Number.isSafeInteger(id) || id <= 0 || entry.adult) return;
    const originalTitle = entry.original_title ?? entry.original_name ?? "";
    rows.push(`(${sqlText(date)}, ${sqlText(mediaType)}, ${id}, ${sqlText(originalTitle)}, ${sqlText(foldText(originalTitle))})`);
    count++;
    if (rows.length === 300) await flush();
  });
  await flush();
  await writeStatementBatches(env.DB, sqlBatch);
  return count;
}

async function stageDailyExports(env, date) {
  const previous = await getState(env.DB, "tmdb_export_date");
  if (previous !== date) {
    await env.DB.prepare("DELETE FROM tmdb_daily_ids").run();
    await stageTmdbExport(env, date, "movie_ids", "movie");
    await stageTmdbExport(env, date, "tv_series_ids", "tv");
    const result = await env.DB.prepare(`UPDATE titles SET original_title=(
        SELECT e.original_title FROM tmdb_daily_ids e
        WHERE e.export_date=? AND e.media_type=titles.media_type AND e.id=titles.id
      ), original_title_folded=(
        SELECT e.original_title_folded FROM tmdb_daily_ids e
        WHERE e.export_date=? AND e.media_type=titles.media_type AND e.id=titles.id
      ), fetched_at=?
      WHERE EXISTS (
        SELECT 1 FROM tmdb_daily_ids e WHERE e.export_date=?
          AND e.media_type=titles.media_type AND e.id=titles.id
          AND e.original_title != titles.original_title
      )`).bind(date, date, Date.now(), date).run();
    await setState(env.DB, "tmdb_export_date", date);
    await setState(env.DB, "tmdb_new_done_date", "");
    await setState(env.DB, "tmdb_refresh_count", "0");
    return result.meta?.changes ?? 0;
  }
  return 0;
}

function tmdbAuth(env, url) {
  const headers = {};
  if (env.TMDB_READ_TOKEN) headers.Authorization = `Bearer ${env.TMDB_READ_TOKEN}`;
  else if (env.TMDB_API_KEY) url.searchParams.set("api_key", env.TMDB_API_KEY);
  else throw new Error("TMDB_READ_TOKEN or TMDB_API_KEY is not configured");
  return headers;
}

async function tmdbJson(env, path) {
  const wait = nextTmdbRequestAt - Date.now();
  if (wait > 0) await pause(wait);
  nextTmdbRequestAt = Date.now() + 50;
  const url = new URL(TMDB + path);
  url.searchParams.set("language", "en-US");
  const headers = tmdbAuth(env, url);
  for (let attempt = 0; attempt < 5; attempt++) {
    const response = await fetch(url, { headers });
    if (response.ok) return response.json();
    if (response.status === 404) return null;
    if (response.status !== 429 && response.status < 500) {
      throw new Error(`TMDB ${path} -> HTTP ${response.status}`);
    }
    await pause(Math.max(1000, Number(response.headers.get("retry-after")) * 1000 || 1000) * (attempt + 1));
  }
  throw new Error(`TMDB ${path} retry limit reached`);
}

function tmdbRecord(mediaType, data, imdbId = "") {
  const date = mediaType === "movie" ? data.release_date : data.first_air_date;
  return {
    id: Number(data.id),
    mediaType,
    title: data.title ?? data.name ?? "",
    originalTitle: data.original_title ?? data.original_name ?? "",
    titleFolded: foldText(data.title ?? data.name ?? ""),
    originalTitleFolded: foldText(data.original_title ?? data.original_name ?? ""),
    year: Number(String(date ?? "").slice(0, 4)) || 0,
    voteCount: Number(data.vote_count) || 0,
    popularity: Number(data.popularity) || 0,
    posterPath: data.poster_path ?? "",
    imdbId: data.imdb_id ?? imdbId ?? "",
    seasonCount: mediaType === "tv" ? Number(data.number_of_seasons) || 0 : 0,
    fetchedAt: Date.now(),
  };
}

async function saveTmdbRecord(db, record) {
  const result = await db.prepare(`INSERT INTO titles(id, media_type, title, original_title, year, vote_count,
      popularity, poster_path, imdb_id, season_count, title_folded, original_title_folded, fetched_at)
    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(media_type, id) DO UPDATE SET title=excluded.title,
      original_title=excluded.original_title, year=excluded.year, vote_count=excluded.vote_count,
      popularity=excluded.popularity, poster_path=excluded.poster_path, imdb_id=excluded.imdb_id,
      season_count=excluded.season_count, title_folded=excluded.title_folded,
      original_title_folded=excluded.original_title_folded, fetched_at=excluded.fetched_at
    WHERE titles.title IS NOT excluded.title OR titles.original_title IS NOT excluded.original_title
      OR titles.year IS NOT excluded.year OR titles.vote_count IS NOT excluded.vote_count
      OR titles.popularity IS NOT excluded.popularity OR titles.poster_path IS NOT excluded.poster_path
      OR titles.imdb_id IS NOT excluded.imdb_id OR titles.season_count IS NOT excluded.season_count
      OR titles.title_folded IS NOT excluded.title_folded
      OR titles.original_title_folded IS NOT excluded.original_title_folded`)
    .bind(record.id, record.mediaType, record.title, record.originalTitle, record.year,
      record.voteCount, record.popularity, record.posterPath, record.imdbId,
      record.seasonCount, record.titleFolded, record.originalTitleFolded, record.fetchedAt).run();
  if (!result.meta?.changes) {
    await db.prepare("UPDATE titles SET fetched_at=? WHERE media_type=? AND id=?")
      .bind(record.fetchedAt, record.mediaType, record.id).run();
  }
  return result.meta?.changes ?? 0;
}

async function fetchTmdbItems(env, items) {
  const records = await Promise.all(items.map(async (item) => {
    const data = await tmdbJson(env, `/${item.media_type}/${item.id}`);
    if (!data) return null;
    let imdbId = "";
    if (item.media_type === "tv") {
      const external = await tmdbJson(env, `/tv/${item.id}/external_ids`);
      imdbId = external?.imdb_id ?? "";
    }
    return tmdbRecord(item.media_type, data, imdbId);
  }));
  let changed = 0;
  for (const record of records) if (record) changed += await saveTmdbRecord(env.DB, record);
  return { fetched: records.filter(Boolean).length, changed };
}

async function syncNewTmdbTitles(env, date) {
  if (await getState(env.DB, "tmdb_new_done_date") === date) return { fetched: 0, changed: 0 };
  const items = await env.DB.prepare(`SELECT e.media_type, e.id FROM tmdb_daily_ids e
    LEFT JOIN titles t ON t.media_type=e.media_type AND t.id=e.id
    WHERE e.export_date=? AND t.id IS NULL LIMIT 50`).bind(date).all();
  const rows = items.results ?? [];
  if (!rows.length) {
    await setState(env.DB, "tmdb_new_done_date", date);
    return { fetched: 0, changed: 0 };
  }
  return fetchTmdbItems(env, rows);
}

async function refreshStaleTmdbTitles(env, date) {
  const count = Number(await getState(env.DB, "tmdb_refresh_count") ?? 0);
  if (count >= 5000) return { fetched: 0, changed: 0 };
  const limit = Math.min(50, 5000 - count);
  const items = await env.DB.prepare(`SELECT media_type, id FROM titles
    ORDER BY CASE WHEN media_type='tv' AND season_count=0 THEN 0 ELSE 1 END, fetched_at ASC
    LIMIT ?`).bind(limit).all();
  const rows = items.results ?? [];
  if (!rows.length) return { fetched: 0, changed: 0 };
  const refreshed = await fetchTmdbItems(env, rows);
  await setState(env.DB, "tmdb_refresh_count", String(count + rows.length));
  if (count + rows.length >= 5000) await setState(env.DB, "tmdb_refresh_date", date);
  return refreshed;
}

async function syncTmdb(env, date) {
  const exportChanges = await stageDailyExports(env, date);
  const inserted = await syncNewTmdbTitles(env, date);
  const refreshed = inserted.fetched ? { fetched: 0, changed: 0 } : await refreshStaleTmdbTitles(env, date);
  return { inserted: inserted.fetched, refreshed: refreshed.fetched,
    changed: exportChanges + inserted.changed + refreshed.changed };
}

async function syncImdbRatings(env, date) {
  if (await getState(env.DB, "imdb_rating_date") === date) return 0;
  const response = await fetch("https://datasets.imdbws.com/title.ratings.tsv.gz");
  if (!response.ok) throw new Error(`IMDb ratings -> HTTP ${response.status}`);
  await env.DB.prepare("DELETE FROM imdb_rating_feed").run();
  let rows = [];
  const statements = [];
  const flush = async () => {
    if (!rows.length) return;
    statements.push(`INSERT INTO imdb_rating_feed(imdb_id, rating) VALUES ${rows.join(",")}
      ON CONFLICT(imdb_id) DO UPDATE SET rating=excluded.rating;`);
    rows = [];
    if (statements.length >= 100) await writeStatementBatches(env.DB, statements.splice(0));
  };
  await streamGzipLines(response, async (line) => {
    const first = line.indexOf("\t");
    const second = line.indexOf("\t", first + 1);
    if (first < 0 || second < 0) return;
    const imdbId = line.slice(0, first);
    if (!imdbId.startsWith("tt")) return;
    const rating = Number.parseFloat(line.slice(first + 1, second));
    if (!Number.isFinite(rating)) return;
    rows.push(`(${sqlText(imdbId)}, ${Math.max(0, Math.min(100, Math.round(rating * 10)))})`);
    if (rows.length === 300) await flush();
  });
  await flush();
  await writeStatementBatches(env.DB, statements);
  const result = await env.DB.prepare(`UPDATE titles SET imdb_rating=i.rating, ratings_at=?
    FROM imdb_rating_feed i WHERE titles.imdb_id=i.imdb_id
      AND titles.imdb_rating IS NOT i.rating`).bind(Date.now()).run();
  await env.DB.prepare("DELETE FROM imdb_rating_feed").run();
  await setState(env.DB, "imdb_rating_date", date);
  return result.meta?.changes ?? 0;
}

function omdbRating(payload, source) {
  const rating = payload?.Ratings?.find((item) => item.Source?.toLowerCase() === source.toLowerCase())?.Value;
  return score100(rating);
}

async function syncOmdb(env, date) {
  if (!env.OMDB_API_KEY) return 0;
  const count = await stateNumber(env.DB, "omdb_requests", date);
  const rows = await env.DB.prepare(`SELECT id, media_type, imdb_id, year, rt_score,
      metacritic_score, metacritic_source, imdb_rating
    FROM titles WHERE imdb_id != '' AND (vote_count >= 5 OR year >= ?)
      AND omdb_checked_at < ?
    ORDER BY CASE WHEN rt_score IS NULL AND metacritic_score IS NULL THEN 0 ELSE 1 END,
      vote_count DESC, omdb_checked_at ASC LIMIT ?`)
    .bind(new Date().getUTCFullYear() - 1, Date.now() - DAY_MS * 30, Math.min(50, 1000 - count)).all();
  let done = 0;
  let changed = 0;
  for (const row of rows.results ?? []) {
    if (done) await pause(200);
    const url = new URL(OMDB);
    url.searchParams.set("apikey", env.OMDB_API_KEY);
    url.searchParams.set("i", row.imdb_id);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`OMDb -> HTTP ${response.status}`);
    const payload = await response.json();
    if (payload?.Error && /invalid api key|limit/i.test(payload.Error)) {
      throw new Error(`OMDb stopped: ${payload.Error}`);
    }
    const rt = omdbRating(payload, "Rotten Tomatoes");
    const meta = omdbRating(payload, "Metacritic");
    const imdb = imdb100(payload?.imdbRating);
    const rtScore = rt ?? row.rt_score;
    const metacritic = meta ?? row.metacritic_score;
    const source = meta !== null ? "omdb" : row.metacritic_source;
    const imdbRating = imdb ?? row.imdb_rating;
    const stamp = Date.now();
    const result = await env.DB.prepare(`UPDATE titles SET rt_score=?, metacritic_score=?, metacritic_source=?,
      imdb_rating=?, ratings_at=?, omdb_checked_at=? WHERE media_type=? AND id=?
      AND (rt_score IS NOT ? OR metacritic_score IS NOT ? OR metacritic_source IS NOT ?
        OR imdb_rating IS NOT ?)`)
      .bind(rtScore, metacritic, source, imdbRating, stamp, stamp, row.media_type, row.id,
        rtScore, metacritic, source, imdbRating).run();
    if (result.meta?.changes) changed += result.meta.changes;
    else await env.DB.prepare(`UPDATE titles SET ratings_at=?, omdb_checked_at=?
      WHERE media_type=? AND id=?`).bind(stamp, stamp, row.media_type, row.id).run();
    done++;
  }
  if (done) await addDailyCount(env.DB, "omdb_requests", date, done);
  return changed;
}

async function loadMDBListChanges(env, date) {
  if (!env.MDBLIST_API_KEY || await getState(env.DB, "mdblist_changes_date") === date) return;
  const mediaType = (await getState(env.DB, "mdblist_feed_type")) === "tv" ? "movie" : "tv";
  const endpoint = mediaType === "tv" ? "shows" : "movies";
  const field = endpoint;
  const feedDate = await getState(env.DB, `mdblist_${mediaType}_feed_date`);
  const cursor = await getState(env.DB, `mdblist_${mediaType}_cursor`);
  if (feedDate !== date && !cursor) {
    const since = Number(await getState(env.DB, "mdblist_since")) || Date.now() - 2 * DAY_MS;
    await setState(env.DB, `mdblist_${mediaType}_since`, new Date(since).toISOString());
  }
  const url = new URL(`${MDBLIST}/${endpoint}/updates`);
  url.searchParams.set("apikey", env.MDBLIST_API_KEY);
  url.searchParams.set("limit", "100");
  if (cursor) url.searchParams.set("cursor", cursor);
  else url.searchParams.set("since", await getState(env.DB, `mdblist_${mediaType}_since`));
  const lastRequest = Number(await getState(env.DB, "mdblist_last_request_at")) || 0;
  if (Date.now() - lastRequest < 1000) await pause(1000 - (Date.now() - lastRequest));
  const response = await fetch(url);
  await setState(env.DB, "mdblist_last_request_at", String(Date.now()));
  await addDailyCount(env.DB, "mdblist_requests", date, 1);
  if (!response.ok) throw new Error(`MDBList ${endpoint} updates -> HTTP ${response.status}`);
  const payload = await response.json();
  const values = [];
  for (const item of payload?.[field] ?? []) {
    const id = Number(item?.ids?.tmdb ?? item?.tmdb ?? item?.tmdbid ?? item?.tmdb_id);
    if (Number.isSafeInteger(id) && id > 0) values.push(`(${sqlText(mediaType)}, ${id})`);
  }
  if (values.length) await env.DB.prepare(`INSERT OR IGNORE INTO mdblist_changes(media_type, id) VALUES ${values.join(",")}`).run();
  const page = payload?.pagination ?? {};
  if (page.has_more && page.next_cursor) {
    await setState(env.DB, `mdblist_${mediaType}_cursor`, page.next_cursor);
  } else {
    await setState(env.DB, `mdblist_${mediaType}_cursor`, "");
    await setState(env.DB, `mdblist_${mediaType}_feed_date`, date);
  }
  const tvDone = await getState(env.DB, "mdblist_tv_feed_date") === date;
  const movieDone = await getState(env.DB, "mdblist_movie_feed_date") === date;
  if (tvDone && movieDone) {
    await setState(env.DB, "mdblist_since", String(Date.now()));
    await setState(env.DB, "mdblist_changes_date", date);
  }
  await setState(env.DB, "mdblist_feed_type", mediaType);
}

function mdblistScore(item) {
  const rating = item?.ratings?.find((entry) => entry.source === "metacritic");
  return score100(rating?.score ?? rating?.value);
}

async function syncMDBList(env, date) {
  if (!env.MDBLIST_API_KEY) return 0;
  await loadMDBListChanges(env, date);
  if (await getState(env.DB, "mdblist_changes_date") !== date) return 0;
  if (await stateNumber(env.DB, "mdblist_requests", date) >= 10000) return 0;
  const rows = await env.DB.prepare(`SELECT t.id, t.media_type, t.metacritic_score,
      t.metacritic_source, t.year, t.vote_count, t.popularity
    FROM mdblist_changes c JOIN titles t ON t.media_type=c.media_type AND t.id=c.id
    WHERE (t.vote_count >= 5 OR t.year >= ? OR t.rt_score IS NOT NULL OR t.imdb_rating IS NOT NULL)
      AND (t.metacritic_score IS NULL OR t.metacritic_source='mdblist')
    ORDER BY CASE WHEN t.media_type='tv' THEN 0 ELSE 1 END LIMIT 200`)
    .bind(new Date().getUTCFullYear() - 1).all();
  const queued = rows.results ?? [];
  const batch = queued.length ? queued : (await env.DB.prepare(`SELECT id, media_type,
      metacritic_score, metacritic_source, year, vote_count, popularity FROM titles
    WHERE (vote_count >= 5 OR year >= ? OR rt_score IS NOT NULL OR imdb_rating IS NOT NULL)
      AND (metacritic_score IS NULL OR metacritic_source='mdblist')
      AND mdblist_ratings_at < ?
    ORDER BY CASE WHEN media_type='tv' THEN 0 ELSE 1 END,
      CASE WHEN year >= ? THEN 0 ELSE 1 END, popularity DESC, vote_count DESC LIMIT 200`)
    .bind(new Date().getUTCFullYear() - 1, Date.now() - DAY_MS * 30,
      new Date().getUTCFullYear() - 1).all()).results ?? [];
  if (!batch.length) return 0;
  const mediaType = batch.some((row) => row.media_type === "tv") ? "tv" : "movie";
  const subset = batch.filter((row) => row.media_type === mediaType);
  const url = new URL(`${MDBLIST}/tmdb/${mediaType === "tv" ? "show" : "movie"}`);
  url.searchParams.set("apikey", env.MDBLIST_API_KEY);
  const lastRequest = Number(await getState(env.DB, "mdblist_last_request_at")) || 0;
  if (Date.now() - lastRequest < 1000) await pause(1000 - (Date.now() - lastRequest));
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ids: subset.map((row) => row.id) }),
  });
  await setState(env.DB, "mdblist_last_request_at", String(Date.now()));
  await addDailyCount(env.DB, "mdblist_requests", date, 1);
  if (response.status === 429) return 0;
  if (!response.ok) throw new Error(`MDBList batch -> HTTP ${response.status}`);
  const payload = await response.json();
  if (!Array.isArray(payload)) throw new Error("MDBList batch response was not an array");
  const byId = new Map(payload.map((item) => [
    Number(item?.ids?.tmdb ?? item?.tmdbid ?? item?.tmdb_id), item,
  ]));
  let changed = 0;
  for (const row of subset) {
    const score = mdblistScore(byId.get(row.id));
    const keepOther = row.metacritic_score != null && row.metacritic_source !== "mdblist";
    const nextScore = keepOther ? row.metacritic_score : (score ?? row.metacritic_score);
    const nextSource = keepOther ? row.metacritic_source
      : (score != null || row.metacritic_source === "mdblist" ? "mdblist" : row.metacritic_source);
    const stamp = Date.now();
    const result = await env.DB.prepare(`UPDATE titles SET metacritic_score=?, metacritic_source=?,
      mdblist_ratings_at=? WHERE media_type=? AND id=?
      AND (metacritic_score IS NOT ? OR metacritic_source IS NOT ?)`)
      .bind(nextScore, nextSource, stamp, row.media_type, row.id, nextScore, nextSource).run();
    if (result.meta?.changes) changed += result.meta.changes;
    else await env.DB.prepare(`UPDATE titles SET mdblist_ratings_at=? WHERE media_type=? AND id=?`)
      .bind(stamp, row.media_type, row.id).run();
  }
  if (queued.length) {
    const binds = subset.map((row) => env.DB.prepare("DELETE FROM mdblist_changes WHERE media_type=? AND id=?").bind(row.media_type, row.id));
    await env.DB.batch(binds);
  }
  return changed;
}

export async function runScheduledIngestion(env) {
  const date = todayUTC();
  const lock = await env.DB.prepare(`INSERT INTO worker_locks(name, expires_at) VALUES('ingestion', ?)
    ON CONFLICT(name) DO UPDATE SET expires_at=excluded.expires_at
    WHERE worker_locks.expires_at < ? RETURNING name`)
    .bind(Date.now() + 14 * 60 * 1000, Date.now()).first();
  if (!lock) return false;
  const results = {};
  try {
    results.tmdb = await syncTmdb(env, latestTmdbExportDate());
    results.imdb = await syncImdbRatings(env, date);
    results.omdb = await syncOmdb(env, date);
    results.mdblist = await syncMDBList(env, date);
    console.log(JSON.stringify({ date, ...results }));
    return Boolean(results.tmdb.changed || results.imdb || results.omdb || results.mdblist ||
      await getState(env.DB, "search_cache_dirty"));
  } finally {
    await env.DB.prepare("UPDATE worker_locks SET expires_at=0 WHERE name='ingestion'").run();
  }
}
