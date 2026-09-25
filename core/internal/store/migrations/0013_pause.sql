-- A pause somebody asked for outlives a restart of the core, and so does how
-- far the download had got when it was paused: nothing else knows it until
-- the transfer runs again.
ALTER TABLE downloads ADD COLUMN paused_by_user INTEGER NOT NULL DEFAULT 0;
ALTER TABLE downloads ADD COLUMN paused_at_bytes INTEGER NOT NULL DEFAULT 0;
