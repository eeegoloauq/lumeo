-- The rows each metadata provider last answered, shown when it cannot be
-- asked: a core linked to a server that is down still has a home screen.
CREATE TABLE catalog_rows (
    provider_id TEXT PRIMARY KEY,
    payload TEXT NOT NULL
);
