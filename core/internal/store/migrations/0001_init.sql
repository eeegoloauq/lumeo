CREATE TABLE items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    year INTEGER NOT NULL DEFAULT 0,
    payload TEXT NOT NULL,
    detailed INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

CREATE TABLE external_ids (
    namespace TEXT NOT NULL,
    external_id TEXT NOT NULL,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    PRIMARY KEY (namespace, external_id)
);

CREATE INDEX external_ids_item_id_idx ON external_ids(item_id);

CREATE TABLE catalog_pages (
    key TEXT PRIMARY KEY,
    item_ids TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
