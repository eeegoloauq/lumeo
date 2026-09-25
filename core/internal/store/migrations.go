package store

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// addonsVersion is the migration that creates the addons table.
const addonsVersion = 4

// migrate brings the schema up to date and reports the version it started
// from, so that Open knows which tables are new to this run.
func migrate(ctx context.Context, db *sql.DB) (before int, err error) {
	var current int
	if err := db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&current); err != nil {
		return 0, fmt.Errorf("read schema version: %w", err)
	}
	before = current

	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return 0, fmt.Errorf("read migrations: %w", err)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		versionText, _, ok := strings.Cut(entry.Name(), "_")
		if !ok {
			return 0, fmt.Errorf("invalid migration name %q", entry.Name())
		}
		version, err := strconv.Atoi(versionText)
		if err != nil || version < 1 {
			return 0, fmt.Errorf("invalid migration name %q", entry.Name())
		}
		if version <= current {
			continue
		}

		body, err := migrationFiles.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return 0, fmt.Errorf("read migration %q: %w", entry.Name(), err)
		}
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return 0, fmt.Errorf("begin migration %q: %w", entry.Name(), err)
		}
		if _, err = tx.ExecContext(ctx, string(body)); err == nil {
			_, err = tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", version))
		}
		if err != nil {
			_ = tx.Rollback()
			return 0, fmt.Errorf("apply migration %q: %w", entry.Name(), err)
		}
		if err := tx.Commit(); err != nil {
			return 0, fmt.Errorf("commit migration %q: %w", entry.Name(), err)
		}
		current = version
	}

	return before, nil
}
