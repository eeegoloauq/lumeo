-- A title taken out of Continue watching has every entry marked; the next
-- write to any of them clears its mark, and a title with one unmarked entry
-- is back in the row. Kept on the entries rather than as a time of its own,
-- so a play in the same second as the hiding still brings it back.
ALTER TABLE progress ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
