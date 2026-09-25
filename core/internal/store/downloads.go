package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
)

var _ acquire.Store = (*DB)(nil)

func (d *DB) SaveDownload(ctx context.Context, download acquire.Download) error {
	// Progress is live backend state; writing it would make the row stale
	// before the next poll. A pause freezes it, so that much is kept.
	locator, err := json.Marshal(download.Locator)
	if err != nil {
		return fmt.Errorf("encode download locator %q: %w", download.ID, err)
	}
	var pausedAt int64
	if download.PausedByUser {
		pausedAt = download.Progress.Completed
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO downloads(
			id, item_id, season, episode, name, scheme, locator,
			dir, file_path, size, state, error, created_at, updated_at,
			paused_by_user, paused_at_bytes
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			paused_by_user = excluded.paused_by_user,
			paused_at_bytes = excluded.paused_at_bytes,
			item_id = excluded.item_id,
			season = excluded.season,
			episode = excluded.episode,
			name = excluded.name,
			scheme = excluded.scheme,
			locator = excluded.locator,
			dir = excluded.dir,
			file_path = excluded.file_path,
			size = excluded.size,
			state = excluded.state,
			error = excluded.error,
			created_at = excluded.created_at,
			updated_at = excluded.updated_at`,
		download.ID, download.ItemID, download.Season, download.Episode, download.Name,
		download.Locator.Scheme, locator, download.Dir, download.FilePath, download.Size,
		string(download.State), download.Error, download.CreatedAt.Unix(), download.UpdatedAt.Unix(),
		download.PausedByUser, pausedAt)
	if err != nil {
		return fmt.Errorf("save download %q: %w", download.ID, err)
	}
	return nil
}

func (d *DB) Downloads(ctx context.Context) ([]acquire.Download, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, item_id, season, episode, name, locator,
		       dir, file_path, size, state, error, created_at, updated_at,
		       paused_by_user, paused_at_bytes
		FROM downloads
		ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("read downloads: %w", err)
	}
	defer rows.Close()

	downloads := make([]acquire.Download, 0)
	for rows.Next() {
		download, err := scanDownload(rows.Scan)
		if err != nil {
			return nil, err
		}
		downloads = append(downloads, download)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read downloads: %w", err)
	}
	return downloads, nil
}

func (d *DB) Download(ctx context.Context, id string) (acquire.Download, bool, error) {
	row := d.db.QueryRowContext(ctx, `
		SELECT id, item_id, season, episode, name, locator,
		       dir, file_path, size, state, error, created_at, updated_at,
		       paused_by_user, paused_at_bytes
		FROM downloads
		WHERE id = ?`, id)
	download, err := scanDownload(row.Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return acquire.Download{}, false, nil
	}
	if err != nil {
		return acquire.Download{}, false, fmt.Errorf("read download %q: %w", id, err)
	}
	return download, true, nil
}

func (d *DB) DeleteDownload(ctx context.Context, id string) error {
	if _, err := d.db.ExecContext(ctx, "DELETE FROM downloads WHERE id = ?", id); err != nil {
		return fmt.Errorf("delete download %q: %w", id, err)
	}
	return nil
}

func scanDownload(scan func(dest ...any) error) (acquire.Download, error) {
	var download acquire.Download
	var locator []byte
	var state string
	var createdAt, updatedAt, pausedAt int64
	if err := scan(
		&download.ID, &download.ItemID, &download.Season, &download.Episode, &download.Name,
		&locator, &download.Dir, &download.FilePath, &download.Size, &state, &download.Error,
		&createdAt, &updatedAt, &download.PausedByUser, &pausedAt,
	); err != nil {
		return acquire.Download{}, err
	}
	if err := json.Unmarshal(locator, &download.Locator); err != nil {
		return acquire.Download{}, fmt.Errorf("decode download locator %q: %w", download.ID, err)
	}
	if download.PausedByUser {
		download.Progress = acquire.Progress{Completed: pausedAt, Total: download.Size}
	}
	download.State = acquire.State(state)
	download.CreatedAt = time.Unix(createdAt, 0).UTC()
	download.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return download, nil
}
