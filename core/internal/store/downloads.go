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
			paused_by_user, paused_at_bytes, binge_group, pack_path
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			paused_by_user = excluded.paused_by_user,
			paused_at_bytes = excluded.paused_at_bytes,
			binge_group = excluded.binge_group,
			pack_path = excluded.pack_path,
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
		download.PausedByUser, pausedAt, download.BingeGroup, download.PackPath)
	if err != nil {
		return fmt.Errorf("save download %q: %w", download.ID, err)
	}
	return nil
}

func (d *DB) Downloads(ctx context.Context) ([]acquire.Download, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, item_id, season, episode, name, locator,
		       dir, file_path, size, state, error, created_at, updated_at,
		       paused_by_user, paused_at_bytes, binge_group, pack_path
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
	holds, err := d.holds(ctx, "")
	if err != nil {
		return nil, err
	}
	for i := range downloads {
		downloads[i].Holds = holds[downloads[i].ID]
	}
	return downloads, nil
}

func (d *DB) Download(ctx context.Context, id string) (acquire.Download, bool, error) {
	row := d.db.QueryRowContext(ctx, `
		SELECT id, item_id, season, episode, name, locator,
		       dir, file_path, size, state, error, created_at, updated_at,
		       paused_by_user, paused_at_bytes, binge_group, pack_path
		FROM downloads
		WHERE id = ?`, id)
	download, err := scanDownload(row.Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return acquire.Download{}, false, nil
	}
	if err != nil {
		return acquire.Download{}, false, fmt.Errorf("read download %q: %w", id, err)
	}
	holds, err := d.holds(ctx, id)
	if err != nil {
		return acquire.Download{}, false, err
	}
	download.Holds = holds[id]
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
		&createdAt, &updatedAt, &download.PausedByUser, &pausedAt, &download.BingeGroup, &download.PackPath,
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

// SaveHolds replaces the holds on a download.
func (d *DB) SaveHolds(ctx context.Context, id string, holds []acquire.Hold) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("save holds of %q: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, "DELETE FROM holds WHERE download_id = ?", id); err != nil {
		return fmt.Errorf("save holds of %q: %w", id, err)
	}
	for _, hold := range holds {
		languages, err := json.Marshal(hold.SubtitleLanguages)
		if err != nil {
			return err
		}
		var watchedAt int64
		if !hold.WatchedAt.IsZero() {
			watchedAt = hold.WatchedAt.Unix()
		}
		if _, err := tx.ExecContext(ctx,
			"INSERT INTO holds(download_id, device_id, watched_at, subtitle_languages) VALUES (?, ?, ?, ?)",
			id, hold.Device, watchedAt, string(languages)); err != nil {
			return fmt.Errorf("save holds of %q: %w", id, err)
		}
	}
	return tx.Commit()
}

// holds is the holds on one download, or on all of them when id is empty,
// by download.
func (d *DB) holds(ctx context.Context, id string) (map[string][]acquire.Hold, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT download_id, device_id, watched_at, subtitle_languages
		FROM holds
		WHERE ? = '' OR download_id = ?
		ORDER BY download_id, device_id`, id, id)
	if err != nil {
		return nil, fmt.Errorf("read holds: %w", err)
	}
	defer rows.Close()
	out := make(map[string][]acquire.Hold)
	for rows.Next() {
		var download, languages string
		var hold acquire.Hold
		var watchedAt int64
		if err := rows.Scan(&download, &hold.Device, &watchedAt, &languages); err != nil {
			return nil, fmt.Errorf("read holds: %w", err)
		}
		if err := json.Unmarshal([]byte(languages), &hold.SubtitleLanguages); err != nil {
			return nil, fmt.Errorf("read holds of %q: %w", download, err)
		}
		if watchedAt != 0 {
			hold.WatchedAt = time.Unix(watchedAt, 0).UTC()
		}
		out[download] = append(out[download], hold)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read holds: %w", err)
	}
	return out, nil
}
