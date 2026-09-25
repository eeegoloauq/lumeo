package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
)

var _ progress.Store = (*DB)(nil)

func (d *DB) UpsertProgress(ctx context.Context, itemID string, entry progress.Entry, watchedOverride *bool) (progress.Entry, error) {
	override := watchedOverride != nil
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO progress(item_id, season, episode, position, duration, watched, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(item_id, season, episode) DO UPDATE SET
			position = excluded.position,
			duration = excluded.duration,
			watched = CASE WHEN ? THEN excluded.watched ELSE max(progress.watched, excluded.watched) END,
			updated_at = excluded.updated_at`,
		itemID, entry.Season, entry.Episode, entry.Position, entry.Duration, entry.Watched, entry.UpdatedAt.Unix(), override)
	if err != nil {
		return progress.Entry{}, fmt.Errorf("save progress for %q: %w", itemID, err)
	}
	row := d.db.QueryRowContext(ctx, `
		SELECT item_id, season, episode, position, duration, watched, updated_at
		FROM progress WHERE item_id = ? AND season = ? AND episode = ?`, itemID, entry.Season, entry.Episode)
	return scanProgress(row.Scan)
}

func (d *DB) Progress(ctx context.Context, itemID string) ([]progress.Entry, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT item_id, season, episode, position, duration, watched, updated_at
		FROM progress WHERE item_id = ? ORDER BY season, episode`, itemID)
	if err != nil {
		return nil, fmt.Errorf("read progress for %q: %w", itemID, err)
	}
	defer rows.Close()
	return scanProgressRows(rows)
}

func (d *DB) AllProgress(ctx context.Context) ([]progress.Entry, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT item_id, season, episode, position, duration, watched, updated_at
		FROM progress ORDER BY updated_at DESC, item_id, season, episode`)
	if err != nil {
		return nil, fmt.Errorf("read progress: %w", err)
	}
	defer rows.Close()
	return scanProgressRows(rows)
}

// History returns the entries that are a viewing — watched, or stopped
// part way — of a title the catalogue knows, the latest first. An entry at
// the start and not watched is an episode marked unwatched, not something
// anybody watched; a local file nothing matched keeps its position under its
// hash, and has no title to be listed by. Both are left out here rather than
// after the page is cut, or a page would come back short of its limit.
func (d *DB) History(ctx context.Context, limit, offset int) ([]progress.Entry, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT item_id, season, episode, position, duration, watched, updated_at
		FROM progress
		WHERE (watched = 1 OR position > 0)
			AND EXISTS (SELECT 1 FROM items WHERE items.id = progress.item_id)
		ORDER BY updated_at DESC, item_id, season DESC, episode DESC
		LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("read history: %w", err)
	}
	defer rows.Close()
	return scanProgressRows(rows)
}

func (d *DB) DeleteProgress(ctx context.Context, itemID string, season, episode *int) error {
	query := "DELETE FROM progress WHERE item_id = ?"
	args := []any{itemID}
	if season != nil && episode != nil {
		query += " AND season = ? AND episode = ?"
		args = append(args, *season, *episode)
	}
	if _, err := d.db.ExecContext(ctx, query, args...); err != nil {
		return fmt.Errorf("delete progress for %q: %w", itemID, err)
	}
	return nil
}

func scanProgressRows(rows *sql.Rows) ([]progress.Entry, error) {
	entries := make([]progress.Entry, 0)
	for rows.Next() {
		entry, err := scanProgress(rows.Scan)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read progress: %w", err)
	}
	return entries, nil
}

func scanProgress(scan func(...any) error) (progress.Entry, error) {
	var entry progress.Entry
	var updatedAt int64
	if err := scan(&entry.ItemID, &entry.Season, &entry.Episode, &entry.Position, &entry.Duration, &entry.Watched, &updatedAt); err != nil {
		return progress.Entry{}, err
	}
	entry.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return entry, nil
}
