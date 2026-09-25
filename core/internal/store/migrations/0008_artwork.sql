CREATE TABLE artwork (
    key TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    missing_until INTEGER NOT NULL DEFAULT 0
);
