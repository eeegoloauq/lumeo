-- A watched entry with a position is now a rewatch under way; the positions
-- left on entries finished before that rule would read as one.
UPDATE progress SET position = 0 WHERE watched = 1;
