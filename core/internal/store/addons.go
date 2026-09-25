package store

import (
	"context"
	"fmt"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/addons"
)

var _ addons.Store = (*DB)(nil)

func (d *DB) Addons(ctx context.Context) ([]addons.Record, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, url, name, enabled, position, manifest
		FROM addons ORDER BY position, created_at, id`)
	if err != nil {
		return nil, fmt.Errorf("read addons: %w", err)
	}
	defer rows.Close()

	var out []addons.Record
	for rows.Next() {
		var r addons.Record
		var manifest string
		if err := rows.Scan(&r.ID, &r.URL, &r.Name, &r.Enabled, &r.Position, &manifest); err != nil {
			return nil, fmt.Errorf("scan addon: %w", err)
		}
		if manifest != "" {
			r.Manifest = []byte(manifest)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read addons: %w", err)
	}
	return out, nil
}

// SeedAddons fills the table on the run that created it and does nothing on
// any later one: the defaults are what a new database starts with, and a
// list somebody emptied on purpose stays empty across a restart. One
// transaction, so the table is either seeded or not.
func (d *DB) SeedAddons(ctx context.Context, records []addons.Record) error {
	if !d.createdAddons {
		return nil
	}
	return d.PutAddons(ctx, records)
}

func (d *DB) PutAddon(ctx context.Context, r addons.Record) error {
	return d.PutAddons(ctx, []addons.Record{r})
}

// PutAddons writes several rows in one transaction: a change that moves one
// addon renumbers the others, and a list half of which has moved is a list
// where two addons share a place.
func (d *DB) PutAddons(ctx context.Context, records []addons.Record) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin addon update: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	now := time.Now().Unix()
	for _, r := range records {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO addons(id, url, name, enabled, position, manifest, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(id) DO UPDATE SET
				url = excluded.url,
				name = excluded.name,
				enabled = excluded.enabled,
				position = excluded.position,
				manifest = excluded.manifest,
				updated_at = excluded.updated_at`,
			r.ID, r.URL, r.Name, r.Enabled, r.Position, string(r.Manifest), now, now)
		if err != nil {
			return fmt.Errorf("write addon %q: %w", r.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit addon update: %w", err)
	}
	return nil
}

func (d *DB) DeleteAddon(ctx context.Context, id string) error {
	if _, err := d.db.ExecContext(ctx, "DELETE FROM addons WHERE id = ?", id); err != nil {
		return fmt.Errorf("delete addon %q: %w", id, err)
	}
	return nil
}
