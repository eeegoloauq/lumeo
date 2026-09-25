CREATE TABLE downloads (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL DEFAULT '',
    season INTEGER NOT NULL DEFAULT 0,
    episode INTEGER NOT NULL DEFAULT 0,
    name TEXT NOT NULL DEFAULT '',
    scheme TEXT NOT NULL,
    locator TEXT NOT NULL,
    dir TEXT NOT NULL DEFAULT '',
    file_path TEXT NOT NULL DEFAULT '',
    size INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL,
    error TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX downloads_item_id_idx ON downloads(item_id);
