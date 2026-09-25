CREATE TABLE progress (
    item_id    TEXT NOT NULL,
    season     INTEGER NOT NULL,   -- 0 for a film
    episode    INTEGER NOT NULL,   -- 0 for a film
    position   REAL NOT NULL,      -- seconds
    duration   REAL NOT NULL,      -- seconds, 0 while unknown
    watched    INTEGER NOT NULL,   -- 0/1
    updated_at INTEGER NOT NULL,   -- unix seconds
    PRIMARY KEY (item_id, season, episode)
);

CREATE INDEX progress_updated ON progress(updated_at);
