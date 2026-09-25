-- Speed stopped being a preference: it belongs to one film, not the household.
DELETE FROM preferences WHERE key = 'playbackSpeed';
