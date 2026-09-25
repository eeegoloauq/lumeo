package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

func (d *DB) Preferences(ctx context.Context) (map[string]json.RawMessage, error) {
	rows, err := d.db.QueryContext(ctx, "SELECT key, value FROM preferences")
	if err != nil {
		return nil, fmt.Errorf("read preferences: %w", err)
	}
	defer rows.Close()

	preferences := make(map[string]json.RawMessage)
	for rows.Next() {
		var key string
		var value []byte
		if err := rows.Scan(&key, &value); err != nil {
			return nil, fmt.Errorf("scan preference: %w", err)
		}
		preferences[key] = append(json.RawMessage(nil), value...)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read preferences: %w", err)
	}
	return preferences, nil
}

func (d *DB) SetPreferences(ctx context.Context, changes map[string]json.RawMessage) error {
	if len(changes) == 0 {
		return nil
	}

	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin preference update: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	now := time.Now().Unix()
	for key, value := range changes {
		if len(value) == 0 {
			if _, err := tx.ExecContext(ctx, "DELETE FROM preferences WHERE key = ?", key); err != nil {
				return fmt.Errorf("delete preference %q: %w", key, err)
			}
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO preferences(key, value, updated_at) VALUES (?, ?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`, key, string(value), now); err != nil {
			return fmt.Errorf("write preference %q: %w", key, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit preference update: %w", err)
	}
	return nil
}
