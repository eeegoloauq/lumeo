-- An external subtitle choice follows its provider to the next episode.
ALTER TABLE choices ADD COLUMN subtitle_provider TEXT;
