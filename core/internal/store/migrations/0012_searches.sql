-- What the viewer searched for, the latest first. The key is the query
-- folded to lower case, so a word searched again moves to the top instead
-- of being listed twice; the query is kept as last typed.
CREATE TABLE searches (
    key         TEXT PRIMARY KEY,
    query       TEXT NOT NULL,
    searched_at INTEGER NOT NULL   -- unix milliseconds
);
