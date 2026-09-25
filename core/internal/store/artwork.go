package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

func (d *DB) RegisterArtwork(ctx context.Context, urls map[string]string) error {
	if len(urls) == 0 {
		return nil
	}
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	query := "INSERT OR IGNORE INTO artwork(key, url) VALUES "
	args := make([]any, 0, min(len(urls), 400)*2)
	flush := func() error {
		_, err := tx.ExecContext(ctx, query+strings.TrimSuffix(strings.Repeat("(?, ?),", len(args)/2), ","), args...)
		return err
	}
	for key, url := range urls {
		args = append(args, key, url)
		if len(args) == 800 {
			if err := flush(); err != nil {
				return err
			}
			args = args[:0]
		}
	}
	if len(args) > 0 {
		if err := flush(); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (d *DB) Artwork(ctx context.Context, key string) (string, int64, error) {
	var url string
	var missingUntil int64
	err := d.db.QueryRowContext(ctx, "SELECT url, missing_until FROM artwork WHERE key = ?", key).Scan(&url, &missingUntil)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, nil
	}
	return url, missingUntil, err
}

func (d *DB) MarkArtworkMissing(ctx context.Context, key string, until int64) error {
	_, err := d.db.ExecContext(ctx, "UPDATE artwork SET missing_until = ? WHERE key = ?", until, key)
	return err
}

func (d *DB) ResetArtworkMissing(ctx context.Context) error {
	_, err := d.db.ExecContext(ctx, "UPDATE artwork SET missing_until = 0")
	return err
}
