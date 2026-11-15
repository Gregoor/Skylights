import { runScheduledIngestion } from "./ingest.js";

const MAX_QUERY_LENGTH = 160;
const MAX_LIMIT = 50;

function json(body, status = 200, cacheControl = "no-store") {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": cacheControl,
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, OPTIONS",
      "access-control-allow-headers": "content-type"
    }
  });
}

function foldedTerms(query) {
  return query.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ").trim().split(/\s+/u).filter(Boolean).slice(0, 12);
}

const RANKED_SEARCH = `
  WITH params(query_term, title_query, year_query, current_year, term_count) AS (
    VALUES (?, ?, ?, ?, ?)
  ),
  candidates AS (
    SELECT t.id, t.media_type, t.title, t.original_title, t.year,
           t.vote_count, t.popularity, t.poster_path, t.imdb_id, t.season_count,
           t.rt_score, t.metacritic_score, t.imdb_rating, t.metacritic_source,
           t.title_folded, t.original_title_folded,
           bm25(titles_fts, 8.0, 4.0, 0.25) AS text_score
    FROM titles_fts
    JOIN titles AS t ON t.rowid = titles_fts.rowid
    WHERE titles_fts MATCH ?
      AND (? IS NULL OR t.media_type = ?)
  ),
  articleless AS (
    SELECT candidates.*,
      CASE
        WHEN title_folded LIKE 'the %' THEN substr(title_folded, 5)
        WHEN title_folded LIKE 'an %' THEN substr(title_folded, 4)
        WHEN title_folded LIKE 'a %' THEN substr(title_folded, 3)
        ELSE title_folded
      END AS title_without_article,
      CASE
        WHEN original_title_folded LIKE 'the %' THEN substr(original_title_folded, 5)
        WHEN original_title_folded LIKE 'an %' THEN substr(original_title_folded, 4)
        WHEN original_title_folded LIKE 'a %' THEN substr(original_title_folded, 3)
        ELSE original_title_folded
      END AS original_without_article
    FROM candidates
  ),
  classified AS (
    SELECT articleless.*,
      CASE
        WHEN params.term_count = 1 THEN CASE
          WHEN title_folded = params.query_term OR title_without_article = params.query_term THEN 1048576
          WHEN substr(title_folded, 1, length(params.query_term)) = params.query_term
            OR substr(title_without_article, 1, length(params.query_term)) = params.query_term THEN 262144
          WHEN instr(' ' || title_folded, ' ' || params.query_term) > 0 THEN 65536
          WHEN length(params.query_term) >= 2 AND instr(title_folded, params.query_term) > 0 THEN 16384
          WHEN original_title_folded != title_folded AND original_title_folded != ''
            AND (original_title_folded = params.query_term OR original_without_article = params.query_term) THEN 1024
          WHEN original_title_folded != title_folded AND original_title_folded != ''
            AND (substr(original_title_folded, 1, length(params.query_term)) = params.query_term
              OR substr(original_without_article, 1, length(params.query_term)) = params.query_term) THEN 512
          WHEN original_title_folded != title_folded AND original_title_folded != ''
            AND instr(' ' || original_title_folded, ' ' || params.query_term) > 0 THEN 256
          ELSE 0
        END
        WHEN params.title_query != '' THEN CASE
          WHEN title_folded = params.title_query OR title_without_article = params.title_query THEN 1048576
          WHEN substr(title_folded, 1, length(params.title_query)) = params.title_query
            OR substr(title_without_article, 1, length(params.title_query)) = params.title_query THEN 262144
          WHEN length(params.title_query) >= 4 AND instr(title_folded, params.title_query) > 0 THEN 16384
          WHEN original_title_folded != title_folded AND original_title_folded != ''
            AND (original_title_folded = params.title_query OR original_without_article = params.title_query) THEN 1024
          ELSE 0
        END
        ELSE 0
      END AS text_tier,
      CASE WHEN params.year_query > 0 AND year = params.year_query THEN 32 ELSE 0 END AS year_bonus,
      CASE
        WHEN year <= 0 OR params.current_year - year > 5 THEN 0
        WHEN year >= params.current_year THEN 3000
        ELSE round(3000.0 * (1.0 - (params.current_year - year) / 5.0))
      END AS recency_bonus,
      min(2500.0, ln(1.0 + max(vote_count, 0)) * 260.0) AS vote_bonus
    FROM articleless CROSS JOIN params
  ),
  ranked AS (
    SELECT classified.*,
      CASE
        WHEN media_type = 'movie' THEN rt_score
        WHEN media_type = 'tv' THEN metacritic_score
        ELSE NULL
      END AS rating_score,
      percent_rank() OVER (PARTITION BY text_tier ORDER BY text_score ASC) AS bm25_percentile
    FROM classified
  ),
  scored AS (
    SELECT ranked.*,
      0.85 * (1.0 - bm25_percentile)
        + 0.15 * coalesce(rating_score / 100.0, 0.5) AS relevance_score
    FROM ranked
  )
  SELECT id, media_type, title, original_title, year, vote_count, popularity,
         poster_path, imdb_id, season_count, rt_score, metacritic_score,
         imdb_rating, metacritic_source, text_score AS score, relevance_score
  FROM scored
  ORDER BY text_tier DESC, relevance_score DESC, year_bonus DESC,
           recency_bonus DESC, vote_bonus DESC, text_score ASC, vote_count DESC, id ASC
  LIMIT ?
`;

export default {
  async scheduled(_controller, env, ctx) {
    const changed = await runScheduledIngestion(env);
    if (changed) {
      try {
        await ctx.cache.purge({ purgeEverything: true });
        await env.DB.prepare("DELETE FROM sync_state WHERE key='search_cache_dirty'").run();
      } catch (error) {
        console.error("search cache purge failed", String(error));
      }
    }
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204 });
    if (request.method !== "GET") return json({ error: "method not allowed" }, 405);

    if (url.pathname === "/healthz") {
      const row = await env.DB.prepare("SELECT 1 AS ok").first();
      return json({ ok: row?.ok === 1 });
    }
    if (url.pathname !== "/search") return json({ error: "not found" }, 404);

    const query = (url.searchParams.get("q") ?? "").trim();
    if (!query || query.length > MAX_QUERY_LENGTH) {
      return json({ error: `q must be 1-${MAX_QUERY_LENGTH} characters` }, 400);
    }
    const terms = foldedTerms(query);
    const match = terms.slice(0, 12).map((term) => `"${term}"*`).join(" AND ");
    if (!match) return json({ query, results: [] });

    const rawLimit = Number(url.searchParams.get("limit") ?? 20);
    const limit = Number.isFinite(rawLimit) ? Math.max(1, Math.min(MAX_LIMIT, Math.floor(rawLimit))) : 20;
    const mediaType = url.searchParams.get("type");
    if (mediaType && mediaType !== "movie" && mediaType !== "tv") {
      return json({ error: "type must be movie or tv" }, 400);
    }

    const titleTerms = terms.length > 1 ? terms.filter((term) => !/^\d{4}$/u.test(term)) : terms;
    const yearQuery = Number(terms.find((term) => /^\d{4}$/u.test(term)) ?? 0);
    const statement = env.DB.prepare(RANKED_SEARCH).bind(
      titleTerms.length === 1 ? titleTerms[0] : "",
      titleTerms.join(" "),
      yearQuery,
      new Date().getUTCFullYear(),
      titleTerms.length,
      match,
      mediaType ?? null,
      mediaType ?? null,
      limit);

    const { results } = await statement.all();
    return json({ query, results }, 200,
      "public, max-age=0, s-maxage=86400, stale-while-revalidate=3600");
  }
};
