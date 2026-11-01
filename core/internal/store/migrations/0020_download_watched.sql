-- When a device said the download's episode was watched, 0 when none has. A
-- core that forwards to this one keeps the viewer's progress itself, and this
-- is all the keep policy here needs of it to free the file.
ALTER TABLE downloads ADD COLUMN watched_at INTEGER NOT NULL DEFAULT 0;
