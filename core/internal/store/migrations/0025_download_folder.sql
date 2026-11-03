-- The folders under the download root a download's directory was made in,
-- "Title (Year)/Season 01": the core's own, taken out once the last download
-- in them goes. Empty for one made straight under the root.
ALTER TABLE downloads ADD COLUMN folder TEXT NOT NULL DEFAULT '';
