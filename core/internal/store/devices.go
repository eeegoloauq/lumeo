package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"time"
)

// Device describes a paired client; its credential is never returned or stored.
type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"createdAt"`
}

func (d *DB) AddDevice(ctx context.Context, device Device, token string) error {
	hash := sha256.Sum256([]byte(token))
	_, err := d.db.ExecContext(ctx, "INSERT INTO devices(id, name, token_hash, created_at) VALUES (?, ?, ?, ?)", device.ID, device.Name, hash[:], device.CreatedAt.Unix())
	return err
}

// DeviceByToken is the id of the device a credential belongs to, ok false
// when none does.
func (d *DB) DeviceByToken(ctx context.Context, token string) (id string, ok bool, err error) {
	hash := sha256.Sum256([]byte(token))
	err = d.db.QueryRowContext(ctx, "SELECT id FROM devices WHERE token_hash = ?", hash[:]).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return id, err == nil, err
}

func (d *DB) Devices(ctx context.Context) ([]Device, error) {
	rows, err := d.db.QueryContext(ctx, "SELECT id, name, created_at FROM devices ORDER BY created_at, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := make([]Device, 0)
	for rows.Next() {
		var device Device
		var created int64
		if err := rows.Scan(&device.ID, &device.Name, &created); err != nil {
			return nil, err
		}
		device.CreatedAt = time.Unix(created, 0).UTC()
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (d *DB) RevokeDevice(ctx context.Context, id string) (bool, error) {
	result, err := d.db.ExecContext(ctx, "DELETE FROM devices WHERE id = ?", id)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	return n > 0, err
}
