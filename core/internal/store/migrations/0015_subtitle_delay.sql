-- How the subtitles of an episode were retimed, so that coming back to it
-- finds them in sync again.
ALTER TABLE progress ADD COLUMN subtitle_delay REAL NOT NULL DEFAULT 0;
