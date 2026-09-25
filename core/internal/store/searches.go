package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/searches"
)

var _ searches.Store = (*DB)(nil)

func (d *DB) RecordSearch(ctx context.Context, query string, at time.Time, keep int) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("record search: %w", err)
	}
	defer tx.Rollback()
	// Each search is stamped after every one before it, even within the same
	// millisecond: an update keeps its row's rowid, so a tie cannot be broken
	// by insertion order and a search repeated at once would not move up.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO searches(key, query, searched_at)
		VALUES (?, ?, MAX(?, COALESCE((SELECT MAX(searched_at) FROM searches) + 1, 0)))
		ON CONFLICT(key) DO UPDATE SET
			query = excluded.query,
			searched_at = excluded.searched_at`,
		strings.ToLower(query), query, at.UnixMilli()); err != nil {
		return fmt.Errorf("record search: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM searches WHERE key NOT IN (
			SELECT key FROM searches ORDER BY searched_at DESC, rowid DESC LIMIT ?
		)`, keep); err != nil {
		return fmt.Errorf("trim searches: %w", err)
	}
	return tx.Commit()
}

func (d *DB) Searches(ctx context.Context) ([]string, error) {
	rows, err := d.db.QueryContext(ctx, "SELECT query FROM searches ORDER BY searched_at DESC, rowid DESC")
	if err != nil {
		return nil, fmt.Errorf("read searches: %w", err)
	}
	defer rows.Close()
	queries := make([]string, 0)
	for rows.Next() {
		var query string
		if err := rows.Scan(&query); err != nil {
			return nil, fmt.Errorf("read searches: %w", err)
		}
		queries = append(queries, query)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read searches: %w", err)
	}
	return queries, nil
}

func (d *DB) ForgetSearch(ctx context.Context, query string) error {
	if _, err := d.db.ExecContext(ctx, "DELETE FROM searches WHERE key = ?", strings.ToLower(query)); err != nil {
		return fmt.Errorf("forget search: %w", err)
	}
	return nil
}

func (d *DB) ClearSearches(ctx context.Context) error {
	if _, err := d.db.ExecContext(ctx, "DELETE FROM searches"); err != nil {
		return fmt.Errorf("clear searches: %w", err)
	}
	return nil
}
