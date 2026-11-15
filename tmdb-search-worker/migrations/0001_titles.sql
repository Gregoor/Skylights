CREATE TABLE titles (
  id INTEGER NOT NULL,
  media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
  title TEXT NOT NULL,
  original_title TEXT NOT NULL DEFAULT '',
  year INTEGER NOT NULL DEFAULT 0,
  vote_count INTEGER NOT NULL DEFAULT 0,
  popularity REAL NOT NULL DEFAULT 0,
  poster_path TEXT NOT NULL DEFAULT '',
  imdb_id TEXT NOT NULL DEFAULT '',
  season_count INTEGER NOT NULL DEFAULT 0,
  fetched_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (media_type, id)
);

CREATE INDEX titles_year ON titles(year);
CREATE INDEX titles_media_year ON titles(media_type, year);

CREATE VIRTUAL TABLE titles_fts USING fts5(
  title,
  original_title,
  year_text,
  content='titles',
  content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER titles_ai AFTER INSERT ON titles BEGIN
  INSERT INTO titles_fts(rowid, title, original_title, year_text)
  VALUES (new.rowid, new.title, new.original_title, CAST(new.year AS TEXT));
END;

CREATE TRIGGER titles_ad AFTER DELETE ON titles BEGIN
  INSERT INTO titles_fts(titles_fts, rowid, title, original_title, year_text)
  VALUES ('delete', old.rowid, old.title, old.original_title, CAST(old.year AS TEXT));
END;

CREATE TRIGGER titles_au AFTER UPDATE ON titles BEGIN
  INSERT INTO titles_fts(titles_fts, rowid, title, original_title, year_text)
  VALUES ('delete', old.rowid, old.title, old.original_title, CAST(old.year AS TEXT));
  INSERT INTO titles_fts(rowid, title, original_title, year_text)
  VALUES (new.rowid, new.title, new.original_title, CAST(new.year AS TEXT));
END;

CREATE TABLE sync_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
