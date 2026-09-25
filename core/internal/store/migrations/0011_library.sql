-- My list: titles the viewer keeps to watch. The rowid breaks ties between
-- two added in the same second.
CREATE TABLE list (
    item_id  TEXT PRIMARY KEY,
    added_at INTEGER NOT NULL      -- unix seconds
);

-- The viewer's own scores, 1 to 10: of a title when season and episode are
-- 0, of one episode otherwise.
CREATE TABLE ratings (
    item_id  TEXT NOT NULL,
    season   INTEGER NOT NULL,
    episode  INTEGER NOT NULL,
    rating   INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 10),
    rated_at INTEGER NOT NULL,     -- unix seconds
    PRIMARY KEY (item_id, season, episode)
);
