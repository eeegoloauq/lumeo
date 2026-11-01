-- A device's hold on a download of a media server, whose progress is kept on
-- the device: whether it watched the episode, and the subtitle languages it
-- wants kept with the file. One mark on the download was one device's word
-- for all of them. Not tied to devices: revoking one releases its holds
-- through the download manager, which keeps them in memory too.
CREATE TABLE holds (
    download_id TEXT NOT NULL REFERENCES downloads(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    watched_at INTEGER NOT NULL DEFAULT 0,
    subtitle_languages TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (download_id, device_id)
);

ALTER TABLE downloads DROP COLUMN watched_at;
