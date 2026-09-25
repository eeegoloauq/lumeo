CREATE TABLE preferences (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,      -- JSON
    updated_at INTEGER NOT NULL    -- unix seconds
);
