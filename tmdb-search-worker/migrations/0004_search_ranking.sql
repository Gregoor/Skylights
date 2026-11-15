ALTER TABLE titles ADD COLUMN title_folded TEXT NOT NULL DEFAULT '';
ALTER TABLE titles ADD COLUMN original_title_folded TEXT NOT NULL DEFAULT '';
ALTER TABLE tmdb_daily_ids ADD COLUMN original_title_folded TEXT NOT NULL DEFAULT '';
