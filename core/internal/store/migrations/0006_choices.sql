-- What the viewer settled on for a title, so that the next episode, or the
-- same film next week, starts from it rather than from the ranking and the
-- file's default tracks. A NULL track is one nobody picked by hand.
CREATE TABLE choices (
    item_id           TEXT PRIMARY KEY,
    binge_group       TEXT NOT NULL DEFAULT '',  -- the pack of the copy started last
    audio_language    TEXT,
    audio_title       TEXT,
    subtitle_language TEXT,
    subtitle_title    TEXT,
    subtitle_off      INTEGER NOT NULL DEFAULT 0,
    updated_at        INTEGER NOT NULL           -- unix seconds
);
