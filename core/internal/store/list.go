package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

var (
	_ watchlist.Store = (*DB)(nil)
	_ ratings.Store   = (*DB)(nil)
)

func (d *DB) AddToList(ctx context.Context, itemID string, at time.Time) (watchlist.Entry, error) {
	if _, err := d.db.ExecContext(ctx, `
		INSERT INTO list(item_id, added_at) VALUES (?, ?)
		ON CONFLICT(item_id) DO NOTHING`, itemID, at.Unix()); err != nil {
		return watchlist.Entry{}, fmt.Errorf("add %q to the list: %w", itemID, err)
	}
	entry, _, err := d.ListEntry(ctx, itemID)
	return entry, err
}

func (d *DB) RemoveFromList(ctx context.Context, itemID string) error {
	if _, err := d.db.ExecContext(ctx, "DELETE FROM list WHERE item_id = ?", itemID); err != nil {
		return fmt.Errorf("remove %q from the list: %w", itemID, err)
	}
	return nil
}

func (d *DB) ListEntry(ctx context.Context, itemID string) (watchlist.Entry, bool, error) {
	var added int64
	err := d.db.QueryRowContext(ctx, "SELECT added_at FROM list WHERE item_id = ?", itemID).Scan(&added)
	if errors.Is(err, sql.ErrNoRows) {
		return watchlist.Entry{}, false, nil
	}
	if err != nil {
		return watchlist.Entry{}, false, fmt.Errorf("read list entry %q: %w", itemID, err)
	}
	return watchlist.Entry{ItemID: itemID, AddedAt: time.Unix(added, 0).UTC()}, true, nil
}

func (d *DB) ListEntries(ctx context.Context) ([]watchlist.Entry, error) {
	rows, err := d.db.QueryContext(ctx, "SELECT item_id, added_at FROM list ORDER BY added_at DESC, rowid DESC")
	if err != nil {
		return nil, fmt.Errorf("read the list: %w", err)
	}
	defer rows.Close()
	entries := make([]watchlist.Entry, 0)
	for rows.Next() {
		var entry watchlist.Entry
		var added int64
		if err := rows.Scan(&entry.ItemID, &added); err != nil {
			return nil, fmt.Errorf("read the list: %w", err)
		}
		entry.AddedAt = time.Unix(added, 0).UTC()
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read the list: %w", err)
	}
	return entries, nil
}

func (d *DB) SaveRating(ctx context.Context, itemID string, rating ratings.Rating) error {
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO ratings(item_id, season, episode, rating, rated_at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(item_id, season, episode) DO UPDATE SET
			rating = excluded.rating,
			rated_at = excluded.rated_at`,
		itemID, rating.Season, rating.Episode, rating.Score, rating.RatedAt.Unix())
	if err != nil {
		return fmt.Errorf("save rating of %q: %w", itemID, err)
	}
	return nil
}

func (d *DB) DeleteRating(ctx context.Context, itemID string, season, episode int) error {
	_, err := d.db.ExecContext(ctx,
		"DELETE FROM ratings WHERE item_id = ? AND season = ? AND episode = ?", itemID, season, episode)
	if err != nil {
		return fmt.Errorf("delete rating of %q: %w", itemID, err)
	}
	return nil
}

func (d *DB) Ratings(ctx context.Context, itemIDs []string) (map[string][]ratings.Rating, error) {
	out := make(map[string][]ratings.Rating)
	if len(itemIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(itemIDs))
	for i, id := range itemIDs {
		args[i] = id
	}
	rows, err := d.db.QueryContext(ctx, `
		SELECT item_id, season, episode, rating, rated_at FROM ratings
		WHERE item_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(itemIDs)), ",")+`)
		ORDER BY item_id, season, episode`, args...)
	if err != nil {
		return nil, fmt.Errorf("read ratings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var itemID string
		var r ratings.Rating
		var rated int64
		if err := rows.Scan(&itemID, &r.Season, &r.Episode, &r.Score, &rated); err != nil {
			return nil, fmt.Errorf("read ratings: %w", err)
		}
		r.RatedAt = time.Unix(rated, 0).UTC()
		out[itemID] = append(out[itemID], r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read ratings: %w", err)
	}
	return out, nil
}
