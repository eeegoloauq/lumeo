-- A hold lasts by its device's keep rules: how long a watched file stays, and
-- how long an unwatched one stays after the device last started or played it.
-- A released hold stays on record until its download goes, so a download
-- every device let go of is freed rather than taken for one nobody held.
-- Holds from before start their clocks now: an upgrade frees nothing.
ALTER TABLE holds ADD COLUMN keep_watched_days INTEGER NOT NULL DEFAULT 1;
ALTER TABLE holds ADD COLUMN keep_unwatched_days INTEGER NOT NULL DEFAULT 7;
ALTER TABLE holds ADD COLUMN active_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE holds ADD COLUMN released_at INTEGER NOT NULL DEFAULT 0;
UPDATE holds SET active_at = CAST(strftime('%s', 'now') AS INTEGER);
