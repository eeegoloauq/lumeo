// Package store persists the media catalog in SQLite.
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	_ "modernc.org/sqlite"
)

type DB struct {
	db *sql.DB
	// createdAddons is whether this Open ran the migration that created the
	// addons table, which is the one moment the table is filled with
	// defaults; see SeedAddons.
	createdAddons bool
}

var _ catalog.Store = (*DB)(nil)

// Open opens the database at path for the core at version.
func Open(path, version string) (*DB, error) {
	if err := mkdirForDatabase(path); err != nil {
		return nil, err
	}

	// Every transaction here writes. Opened deferred, one would start as a
	// reader and ask for the write lock only at its first UPDATE — and when
	// another transaction committed in between, SQLite refuses the upgrade
	// at once instead of waiting out busy_timeout (SQLITE_BUSY_SNAPSHOT).
	// Two pages opened quickly one after another hit exactly that. Immediate
	// takes the lock up front, where the timeout applies.
	db, err := sql.Open("sqlite", "file:"+path+"?_txlock=immediate&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(on)")
	if err != nil {
		return nil, fmt.Errorf("open sqlite database: %w", err)
	}
	before, err := migrate(context.Background(), db)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := expireCatalog(context.Background(), db, version); err != nil {
		_ = db.Close()
		return nil, err
	}
	// SQLite creates the file 0644. The directory is already 0700, but the
	// file should carry its own protection in case it is ever moved.
	if err := os.Chmod(path, 0o600); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("restrict database permissions: %w", err)
	}

	return &DB{db: db, createdAddons: before < addonsVersion}, nil
}

// expireCatalog marks the cached catalog stale when another core version
// wrote it: rows hold what that version's code made of the provider's
// answer, and a newer parser must not wait out the TTL to take effect.
func expireCatalog(ctx context.Context, db *sql.DB, version string) error {
	var stored string
	err := db.QueryRowContext(ctx, "SELECT version FROM core_version").Scan(&stored)
	if err == nil && stored == version {
		return nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("read core version: %w", err)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin catalog expiry: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, statement := range []string{
		"UPDATE items SET updated_at = 0",
		"UPDATE catalog_pages SET updated_at = 0",
		"DELETE FROM core_version",
	} {
		if _, err := tx.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("expire catalog: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO core_version(version) VALUES (?)", version); err != nil {
		return fmt.Errorf("write core version: %w", err)
	}
	return tx.Commit()
}

func mkdirForDatabase(path string) error {
	dir := filepath.Dir(path)
	// The database holds the whole watch history and the addon URLs, which
	// can carry account keys; keep it to its owner. MkdirAll leaves the mode
	// of a directory that exists alone, and SQLite's journal files beside the
	// database are created world-readable, so the directory is what guards.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create database directory %q: %w", dir, err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("restrict database directory %q: %w", dir, err)
	}
	return nil
}

func (d *DB) Close() error {
	return d.db.Close()
}

func (d *DB) UpsertItems(ctx context.Context, namespace string, items []catalog.MediaItem, detailed bool) ([]catalog.MediaItem, error) {
	result := append([]catalog.MediaItem(nil), items...)
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin item upsert: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for i, incoming := range items {
		externalID := incoming.ExternalIDs[namespace]
		if externalID == "" {
			continue
		}

		itemID, found, err := findItemID(ctx, tx, namespace, externalID)
		if err != nil {
			return nil, err
		}

		var merged catalog.MediaItem
		if found {
			stored, err := itemInTx(ctx, tx, itemID)
			if err != nil {
				return nil, err
			}
			merged = mergeItems(stored, incoming)
		} else {
			itemID, err = newItemID()
			if err != nil {
				return nil, err
			}
			merged = cloneItem(incoming)
			merged.ID = itemID
		}

		payload, err := json.Marshal(merged)
		if err != nil {
			return nil, fmt.Errorf("encode item %q: %w", itemID, err)
		}
		now := time.Now().Unix()
		if found {
			_, err = tx.ExecContext(ctx, `
				UPDATE items
				SET kind = ?, title = ?, year = ?, payload = ?,
				    detailed = CASE WHEN detailed = 1 OR ? THEN 1 ELSE 0 END,
				    updated_at = CASE WHEN detailed = 0 OR ? THEN ? ELSE updated_at END
				WHERE id = ?`, merged.Kind, merged.Title, merged.Year, payload, detailed, detailed, now, itemID)
		} else {
			_, err = tx.ExecContext(ctx, `
				INSERT INTO items(id, kind, title, year, payload, detailed, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?)`, itemID, merged.Kind, merged.Title, merged.Year, payload, detailed, now)
		}
		if err != nil {
			return nil, fmt.Errorf("write item %q: %w", itemID, err)
		}

		for externalNamespace, id := range merged.ExternalIDs {
			if id == "" {
				continue
			}
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO external_ids(namespace, external_id, item_id)
				VALUES (?, ?, ?)
				ON CONFLICT(namespace, external_id) DO NOTHING`, externalNamespace, id, itemID); err != nil {
				return nil, fmt.Errorf("write external id %s:%s: %w", externalNamespace, id, err)
			}
		}
		result[i] = merged
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit item upsert: %w", err)
	}
	return result, nil
}

func (d *DB) Item(ctx context.Context, id string) (catalog.MediaItem, catalog.ItemState, error) {
	var payload []byte
	var detailed bool
	var updatedAt int64
	err := d.db.QueryRowContext(ctx, "SELECT payload, detailed, updated_at FROM items WHERE id = ?", id).Scan(&payload, &detailed, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return catalog.MediaItem{}, catalog.ItemState{}, nil
	}
	if err != nil {
		return catalog.MediaItem{}, catalog.ItemState{}, fmt.Errorf("read item %q: %w", id, err)
	}

	item, err := decodeItem(payload)
	if err != nil {
		return catalog.MediaItem{}, catalog.ItemState{}, fmt.Errorf("decode item %q: %w", id, err)
	}
	return item, catalog.ItemState{Found: true, Detailed: detailed, UpdatedAt: fetchedAt(updatedAt)}, nil
}

func (d *DB) ItemsByIDs(ctx context.Context, ids []string) ([]catalog.MediaItem, error) {
	if len(ids) == 0 {
		return []catalog.MediaItem{}, nil
	}

	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	query := "SELECT id, payload FROM items WHERE id IN (" + strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",") + ")"
	rows, err := d.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("read items: %w", err)
	}
	defer rows.Close()

	byID := make(map[string]catalog.MediaItem, len(ids))
	for rows.Next() {
		var id string
		var payload []byte
		if err := rows.Scan(&id, &payload); err != nil {
			return nil, fmt.Errorf("scan item: %w", err)
		}
		item, err := decodeItem(payload)
		if err != nil {
			return nil, fmt.Errorf("decode item %q: %w", id, err)
		}
		byID[id] = item
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read items: %w", err)
	}

	result := make([]catalog.MediaItem, 0, len(ids))
	for _, id := range ids {
		if item, ok := byID[id]; ok {
			result = append(result, item)
		}
	}
	return result, nil
}

func (d *DB) SavePage(ctx context.Context, key string, itemIDs []string) error {
	payload, err := json.Marshal(itemIDs)
	if err != nil {
		return fmt.Errorf("encode page %q: %w", key, err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO catalog_pages(key, item_ids, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET item_ids = excluded.item_ids, updated_at = excluded.updated_at`, key, payload, time.Now().Unix())
	if err != nil {
		return fmt.Errorf("save page %q: %w", key, err)
	}
	return nil
}

func (d *DB) Page(ctx context.Context, key string) ([]string, time.Time, error) {
	var payload []byte
	var updatedAt int64
	err := d.db.QueryRowContext(ctx, "SELECT item_ids, updated_at FROM catalog_pages WHERE key = ?", key).Scan(&payload, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, time.Time{}, nil
	}
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("read page %q: %w", key, err)
	}

	var itemIDs []string
	if err := json.Unmarshal(payload, &itemIDs); err != nil {
		return nil, time.Time{}, fmt.Errorf("decode page %q: %w", key, err)
	}
	return itemIDs, fetchedAt(updatedAt), nil
}

// fetchedAt reads a catalog row's updated_at. 0 is expireCatalog's mark for a
// row another core version wrote, and it comes back as the zero time: the
// catalog must not serve that row while it fetches a new one.
func fetchedAt(unix int64) time.Time {
	if unix == 0 {
		return time.Time{}
	}
	return time.Unix(unix, 0).UTC()
}

func findItemID(ctx context.Context, tx *sql.Tx, namespace, externalID string) (string, bool, error) {
	var id string
	err := tx.QueryRowContext(ctx, "SELECT item_id FROM external_ids WHERE namespace = ? AND external_id = ?", namespace, externalID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("find external id %s:%s: %w", namespace, externalID, err)
	}
	return id, true, nil
}

func itemInTx(ctx context.Context, tx *sql.Tx, id string) (catalog.MediaItem, error) {
	var payload []byte
	if err := tx.QueryRowContext(ctx, "SELECT payload FROM items WHERE id = ?", id).Scan(&payload); err != nil {
		return catalog.MediaItem{}, fmt.Errorf("read item %q: %w", id, err)
	}
	item, err := decodeItem(payload)
	if err != nil {
		return catalog.MediaItem{}, fmt.Errorf("decode item %q: %w", id, err)
	}
	return item, nil
}

func decodeItem(payload []byte) (catalog.MediaItem, error) {
	var item catalog.MediaItem
	err := json.Unmarshal(payload, &item)
	return item, err
}

func newItemID() (string, error) {
	var value [8]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate item id: %w", err)
	}
	return hex.EncodeToString(value[:]), nil
}

func cloneItem(item catalog.MediaItem) catalog.MediaItem {
	cloned := item
	cloned.ExternalIDs = mergeMaps(nil, item.ExternalIDs)
	cloned.Genres = append([]string(nil), item.Genres...)
	cloned.Cast = append([]string(nil), item.Cast...)
	cloned.Directors = append([]string(nil), item.Directors...)
	cloned.Episodes = append([]catalog.Episode(nil), item.Episodes...)
	return cloned
}

func mergeItems(stored, incoming catalog.MediaItem) catalog.MediaItem {
	merged := cloneItem(stored)
	merged.ID = stored.ID
	if incoming.Kind != "" {
		merged.Kind = incoming.Kind
	}
	if incoming.Title != "" {
		merged.Title = incoming.Title
	}
	if incoming.Year != 0 {
		merged.Year = incoming.Year
	}
	if incoming.YearEnd != 0 {
		merged.YearEnd = incoming.YearEnd
	}
	if incoming.Overview != "" {
		merged.Overview = incoming.Overview
	}
	if incoming.Poster != "" {
		merged.Poster = incoming.Poster
	}
	if incoming.Background != "" {
		merged.Background = incoming.Background
	}
	if incoming.Logo != "" {
		merged.Logo = incoming.Logo
	}
	if len(incoming.Genres) != 0 {
		merged.Genres = append([]string(nil), incoming.Genres...)
	}
	if len(incoming.Cast) != 0 {
		merged.Cast = append([]string(nil), incoming.Cast...)
	}
	if len(incoming.Directors) != 0 {
		merged.Directors = append([]string(nil), incoming.Directors...)
	}
	if incoming.Runtime != "" {
		merged.Runtime = incoming.Runtime
	}
	if incoming.IMDbRating != 0 {
		merged.IMDbRating = incoming.IMDbRating
	}
	merged.ExternalIDs = mergeMaps(merged.ExternalIDs, incoming.ExternalIDs)
	if len(incoming.Episodes) != 0 {
		merged.Episodes = append([]catalog.Episode(nil), incoming.Episodes...)
	}
	return merged
}

func mergeMaps(stored, incoming catalog.ExternalIDs) catalog.ExternalIDs {
	if len(stored) == 0 && len(incoming) == 0 {
		return nil
	}
	merged := make(catalog.ExternalIDs, len(stored)+len(incoming))
	for namespace, id := range stored {
		merged[namespace] = id
	}
	for namespace, id := range incoming {
		if id != "" {
			merged[namespace] = id
		}
	}
	return merged
}
