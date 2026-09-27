-- Sharing stopped being a preference: a torrent shares while it fetches or plays.
DELETE FROM preferences WHERE key = 'seed';
