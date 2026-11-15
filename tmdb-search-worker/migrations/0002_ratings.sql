ALTER TABLE titles ADD COLUMN rt_score INTEGER;
ALTER TABLE titles ADD COLUMN metacritic_score INTEGER;
ALTER TABLE titles ADD COLUMN imdb_rating INTEGER;
ALTER TABLE titles ADD COLUMN metacritic_source TEXT;
ALTER TABLE titles ADD COLUMN ratings_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE titles ADD COLUMN mdblist_ratings_at INTEGER NOT NULL DEFAULT 0;

DROP TRIGGER titles_au;
CREATE TRIGGER titles_au AFTER UPDATE OF title, original_title, year ON titles BEGIN
  INSERT INTO titles_fts(titles_fts, rowid, title, original_title, year_text)
  VALUES ('delete', old.rowid, old.title, old.original_title, CAST(old.year AS TEXT));
  INSERT INTO titles_fts(rowid, title, original_title, year_text)
  VALUES (new.rowid, new.title, new.original_title, CAST(new.year AS TEXT));
END;

CREATE INDEX titles_imdb_id ON titles(imdb_id);
CREATE INDEX titles_rating_queue ON titles(year, ratings_at);
