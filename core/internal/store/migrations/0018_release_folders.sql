-- Which pack a download came from and where in it, so the copies on disk can
-- be told apart by release and folder rather than by file: a season is one
-- pack or a run of single-episode releases, and either way one choice. ''
-- for downloads from before these columns and for files on this machine.
ALTER TABLE downloads ADD COLUMN binge_group TEXT NOT NULL DEFAULT '';
ALTER TABLE downloads ADD COLUMN pack_path TEXT NOT NULL DEFAULT '';
-- The torrent of the copy picked, for a pick whose provider gave no pack
-- name; a folder on this machine picked as the title's copy; and whether the
-- release was picked by hand, which puts it ahead of other releases' copies
-- already on disk.
ALTER TABLE choices ADD COLUMN info_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE choices ADD COLUMN dir TEXT NOT NULL DEFAULT '';
ALTER TABLE choices ADD COLUMN picked INTEGER NOT NULL DEFAULT 0;
