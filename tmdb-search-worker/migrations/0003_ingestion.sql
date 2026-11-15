ALTER TABLE titles ADD COLUMN omdb_checked_at INTEGER NOT NULL DEFAULT 0;

CREATE TABLE tmdb_daily_ids (
  export_date TEXT NOT NULL,
  media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
  id INTEGER NOT NULL,
  original_title TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (export_date, media_type, id)
);

CREATE TABLE imdb_rating_feed (
  imdb_id TEXT PRIMARY KEY,
  rating INTEGER NOT NULL
);

CREATE TABLE mdblist_changes (
  media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
  id INTEGER NOT NULL,
  PRIMARY KEY (media_type, id)
);

CREATE TABLE worker_locks (
  name TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
