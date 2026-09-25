CREATE TABLE addons (
    id          TEXT PRIMARY KEY,
    url         TEXT NOT NULL,     -- the addon root, without /manifest.json
    name        TEXT NOT NULL,
    enabled     INTEGER NOT NULL DEFAULT 1,
    position    INTEGER NOT NULL,  -- list order; the tiebreak between addons
    manifest    TEXT NOT NULL DEFAULT '',  -- JSON, the last manifest fetched
    created_at  INTEGER NOT NULL,  -- unix seconds
    updated_at  INTEGER NOT NULL
);
