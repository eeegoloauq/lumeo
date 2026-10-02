-- keep "30days" predates keepDays; it becomes the pair it always meant, and a
-- stored keepDays gives way to it, as it did when read.
INSERT INTO preferences(key, value, updated_at)
SELECT 'keepDays', '30', CAST(strftime('%s', 'now') AS INTEGER)
FROM preferences WHERE key = 'keep' AND json_extract(value, '$') = '30days'
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
UPDATE preferences SET value = '"days"'
WHERE key = 'keep' AND json_extract(value, '$') = '30days';
