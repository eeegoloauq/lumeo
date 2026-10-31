CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    token_hash BLOB NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
);
