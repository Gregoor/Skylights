CREATE TRIGGER titles_search_cache_dirty_ai AFTER INSERT ON titles BEGIN
  INSERT INTO sync_state(key, value) VALUES ('search_cache_dirty', '1')
  ON CONFLICT(key) DO UPDATE SET value='1';
END;

CREATE TRIGGER titles_search_cache_dirty_au
AFTER UPDATE OF title, original_title, year, vote_count, popularity, poster_path, imdb_id,
  season_count, rt_score, metacritic_score, imdb_rating, metacritic_source,
  title_folded, original_title_folded ON titles
WHEN OLD.title IS NOT NEW.title OR OLD.original_title IS NOT NEW.original_title
  OR OLD.year IS NOT NEW.year OR OLD.vote_count IS NOT NEW.vote_count
  OR OLD.popularity IS NOT NEW.popularity OR OLD.poster_path IS NOT NEW.poster_path
  OR OLD.imdb_id IS NOT NEW.imdb_id OR OLD.season_count IS NOT NEW.season_count
  OR OLD.rt_score IS NOT NEW.rt_score OR OLD.metacritic_score IS NOT NEW.metacritic_score
  OR OLD.imdb_rating IS NOT NEW.imdb_rating OR OLD.metacritic_source IS NOT NEW.metacritic_source
  OR OLD.title_folded IS NOT NEW.title_folded
  OR OLD.original_title_folded IS NOT NEW.original_title_folded
BEGIN
  INSERT INTO sync_state(key, value) VALUES ('search_cache_dirty', '1')
  ON CONFLICT(key) DO UPDATE SET value='1';
END;
