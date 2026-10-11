-- The folder of the copy started last, inside its pack: one pack can hold an
-- episode twice, in two cuts, and the pack alone does not say which one the
-- viewer is watching. '' for a copy at the pack's root, and for picks made
-- before this column, which matched any file of the pack.
ALTER TABLE choices ADD COLUMN folder TEXT NOT NULL DEFAULT '';
