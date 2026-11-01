package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/personal"
)

var _ personal.Store = (*DB)(nil)

func (d *DB) ExportPersonal(ctx context.Context) ([]personal.Title, []personal.Search, error) {
	tx, err := d.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, nil, fmt.Errorf("begin export: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	titles, byItem, err := exportTitles(ctx, tx)
	if err != nil {
		return nil, nil, err
	}
	if err := exportProgress(ctx, tx, byItem); err != nil {
		return nil, nil, err
	}
	if err := exportRatings(ctx, tx, byItem); err != nil {
		return nil, nil, err
	}
	if err := exportTracks(ctx, tx, byItem); err != nil {
		return nil, nil, err
	}
	found, err := exportSearches(ctx, tx)
	if err != nil {
		return nil, nil, err
	}
	out := make([]personal.Title, len(titles))
	for i, t := range titles {
		out[i] = *t
	}
	return out, found, nil
}

// exportTitles reads the titles that have any of the viewer's data and an
// IMDb id, by IMDb id, with their place on My list.
func exportTitles(ctx context.Context, tx *sql.Tx) ([]*personal.Title, map[string]*personal.Title, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT items.id, external_ids.external_id, items.kind, items.title, items.year, items.payload, list.added_at
		FROM items
		JOIN external_ids ON external_ids.item_id = items.id AND external_ids.namespace = ?
		LEFT JOIN list ON list.item_id = items.id
		WHERE items.id IN (
			SELECT item_id FROM progress
			UNION SELECT item_id FROM ratings
			UNION SELECT item_id FROM list
			UNION SELECT item_id FROM choices
				WHERE audio_language IS NOT NULL OR subtitle_language IS NOT NULL OR subtitle_off = 1
		)
		ORDER BY external_ids.external_id`, catalog.NamespaceIMDb)
	if err != nil {
		return nil, nil, fmt.Errorf("export titles: %w", err)
	}
	defer rows.Close()
	var titles []*personal.Title
	byItem := make(map[string]*personal.Title)
	for rows.Next() {
		var id string
		var payload []byte
		var listed sql.NullInt64
		t := &personal.Title{}
		if err := rows.Scan(&id, &t.IMDb, &t.Kind, &t.Name, &t.Year, &payload, &listed); err != nil {
			return nil, nil, fmt.Errorf("export titles: %w", err)
		}
		// One title can carry an IMDb id under two of ours only if a
		// provider renamed it; the first keeps it, as a lookup by it would.
		if byItem[id] != nil {
			continue
		}
		if item, err := decodeItem(payload); err == nil {
			t.Poster = item.Poster
		}
		if listed.Valid {
			at := time.Unix(listed.Int64, 0).UTC()
			t.ListedAt = &at
		}
		titles = append(titles, t)
		byItem[id] = t
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("export titles: %w", err)
	}
	return titles, byItem, nil
}

func exportProgress(ctx context.Context, tx *sql.Tx, byItem map[string]*personal.Title) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT item_id, season, episode, position, duration, watched, updated_at, subtitle_delay
		FROM progress ORDER BY item_id, season, episode`)
	if err != nil {
		return fmt.Errorf("export progress: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var p personal.Progress
		var updated int64
		if err := rows.Scan(&id, &p.Season, &p.Episode, &p.Position, &p.Duration, &p.Watched, &updated, &p.SubtitleDelay); err != nil {
			return fmt.Errorf("export progress: %w", err)
		}
		if t := byItem[id]; t != nil {
			p.UpdatedAt = time.Unix(updated, 0).UTC()
			t.Progress = append(t.Progress, p)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("export progress: %w", err)
	}
	return nil
}

func exportRatings(ctx context.Context, tx *sql.Tx, byItem map[string]*personal.Title) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT item_id, season, episode, rating, rated_at FROM ratings ORDER BY item_id, season, episode`)
	if err != nil {
		return fmt.Errorf("export ratings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var r personal.Rating
		var rated int64
		if err := rows.Scan(&id, &r.Season, &r.Episode, &r.Score, &rated); err != nil {
			return fmt.Errorf("export ratings: %w", err)
		}
		if t := byItem[id]; t != nil {
			r.RatedAt = time.Unix(rated, 0).UTC()
			t.Ratings = append(t.Ratings, r)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("export ratings: %w", err)
	}
	return nil
}

func exportTracks(ctx context.Context, tx *sql.Tx, byItem map[string]*personal.Title) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT item_id, audio_language, audio_title, subtitle_language, subtitle_title, subtitle_off, updated_at
		FROM choices`)
	if err != nil {
		return fmt.Errorf("export tracks: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var c trackColumns
		var updated int64
		if err := rows.Scan(&id, &c.audioLanguage, &c.audioTitle, &c.subtitleLanguage, &c.subtitleTitle, &c.subtitleOff, &updated); err != nil {
			return fmt.Errorf("export tracks: %w", err)
		}
		t := byItem[id]
		audio, subtitle := c.tracks()
		if t == nil || (audio == nil && subtitle == nil) {
			continue
		}
		t.Tracks = &personal.Tracks{Audio: audio, Subtitle: subtitle, UpdatedAt: time.Unix(updated, 0).UTC()}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("export tracks: %w", err)
	}
	return nil
}

func exportSearches(ctx context.Context, tx *sql.Tx) ([]personal.Search, error) {
	rows, err := tx.QueryContext(ctx, "SELECT query, searched_at FROM searches ORDER BY searched_at DESC, rowid DESC")
	if err != nil {
		return nil, fmt.Errorf("export searches: %w", err)
	}
	defer rows.Close()
	found := make([]personal.Search, 0)
	for rows.Next() {
		var s personal.Search
		var at int64
		if err := rows.Scan(&s.Query, &at); err != nil {
			return nil, fmt.Errorf("export searches: %w", err)
		}
		s.SearchedAt = time.UnixMilli(at).UTC()
		found = append(found, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("export searches: %w", err)
	}
	return found, nil
}

func (d *DB) ImportPersonal(ctx context.Context, titles []personal.Title, found []personal.Search, prefs map[string]json.RawMessage, searchKeep int) (personal.Counts, error) {
	var counts personal.Counts
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return counts, fmt.Errorf("begin import: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for _, t := range titles {
		if err := importTitle(ctx, tx, t, &counts); err != nil {
			return personal.Counts{}, err
		}
	}
	if counts.Searches, err = importSearches(ctx, tx, found, searchKeep); err != nil {
		return personal.Counts{}, err
	}
	if counts.Preferences, err = importPreferences(ctx, tx, prefs); err != nil {
		return personal.Counts{}, err
	}
	if err := tx.Commit(); err != nil {
		return personal.Counts{}, fmt.Errorf("commit import: %w", err)
	}
	return counts, nil
}

// importTitle finds the title by its IMDb id, or adds its catalogue row, and
// merges the viewer's data about it: an entry is written where the core has
// none or an older one.
func importTitle(ctx context.Context, tx *sql.Tx, t personal.Title, counts *personal.Counts) error {
	id, found, err := findItemID(ctx, tx, catalog.NamespaceIMDb, t.IMDb)
	if err != nil {
		return err
	}
	if !found {
		// A catalogue row, not details: the title's page fetches those the
		// first time it is opened.
		item, err := upsertItem(ctx, tx, catalog.NamespaceIMDb, catalog.MediaItem{
			Kind:        t.Kind,
			Title:       t.Name,
			Year:        t.Year,
			Poster:      t.Poster,
			ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: t.IMDb},
		}, false)
		if err != nil {
			return err
		}
		id = item.ID
		counts.Titles++
	}

	// exec counts the rows a statement wrote: an upsert whose WHERE kept
	// the core's newer entry writes none.
	exec := func(what, query string, args ...any) (int, error) {
		result, err := tx.ExecContext(ctx, query, args...)
		if err != nil {
			return 0, fmt.Errorf("import %s of %s: %w", what, t.IMDb, err)
		}
		n, err := result.RowsAffected()
		return int(n), err
	}
	// My list keeps the date of an entry the core already has.
	if t.ListedAt != nil {
		n, err := exec("list entry", `
			INSERT INTO list(item_id, added_at) VALUES (?, ?)
			ON CONFLICT(item_id) DO NOTHING`, id, t.ListedAt.Unix())
		if err != nil {
			return err
		}
		counts.List += n
	}
	for _, p := range t.Progress {
		n, err := exec("progress", `
			INSERT INTO progress(item_id, season, episode, position, duration, watched, updated_at, subtitle_delay)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(item_id, season, episode) DO UPDATE SET
				position = excluded.position,
				duration = excluded.duration,
				watched = excluded.watched,
				updated_at = excluded.updated_at,
				subtitle_delay = excluded.subtitle_delay
			WHERE excluded.updated_at > progress.updated_at`,
			id, p.Season, p.Episode, p.Position, p.Duration, p.Watched, p.UpdatedAt.Unix(), p.SubtitleDelay)
		if err != nil {
			return err
		}
		counts.Progress += n
	}
	for _, r := range t.Ratings {
		n, err := exec("rating", `
			INSERT INTO ratings(item_id, season, episode, rating, rated_at) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(item_id, season, episode) DO UPDATE SET
				rating = excluded.rating,
				rated_at = excluded.rated_at
			WHERE excluded.rated_at > ratings.rated_at`,
			id, r.Season, r.Episode, r.Score, r.RatedAt.Unix())
		if err != nil {
			return err
		}
		counts.Ratings += n
	}
	if tr := t.Tracks; tr != nil {
		c := columnsOf(tr.Audio, tr.Subtitle)
		// The copy picked stays this core's: only the tracks move.
		n, err := exec("tracks", `
			INSERT INTO choices(item_id, audio_language, audio_title, subtitle_language, subtitle_title, subtitle_off, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(item_id) DO UPDATE SET
				audio_language = excluded.audio_language,
				audio_title = excluded.audio_title,
				subtitle_language = excluded.subtitle_language,
				subtitle_title = excluded.subtitle_title,
				subtitle_off = excluded.subtitle_off,
				updated_at = excluded.updated_at
			WHERE excluded.updated_at > choices.updated_at`,
			id, c.audioLanguage, c.audioTitle, c.subtitleLanguage, c.subtitleTitle, c.subtitleOff, tr.UpdatedAt.Unix())
		if err != nil {
			return err
		}
		counts.Tracks += n
	}
	return nil
}

// importSearches merges found into the search history, keeping the latest
// keep, and counts the ones written that are still among them.
func importSearches(ctx context.Context, tx *sql.Tx, found []personal.Search, keep int) (int, error) {
	if len(found) == 0 {
		return 0, nil
	}
	var keys []any
	for _, s := range found {
		result, err := tx.ExecContext(ctx, `
			INSERT INTO searches(key, query, searched_at) VALUES (?, ?, ?)
			ON CONFLICT(key) DO UPDATE SET
				query = excluded.query,
				searched_at = excluded.searched_at
			WHERE excluded.searched_at > searches.searched_at`,
			strings.ToLower(s.Query), s.Query, s.SearchedAt.UnixMilli())
		if err != nil {
			return 0, fmt.Errorf("import search: %w", err)
		}
		if n, err := result.RowsAffected(); err != nil {
			return 0, err
		} else if n > 0 {
			keys = append(keys, strings.ToLower(s.Query))
		}
	}
	if err := trimSearches(ctx, tx, keep); err != nil {
		return 0, err
	}
	if len(keys) == 0 {
		return 0, nil
	}
	var kept int
	err := tx.QueryRowContext(ctx, "SELECT count(*) FROM searches WHERE key IN ("+
		strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",")+")", keys...).Scan(&kept)
	if err != nil {
		return 0, fmt.Errorf("import searches: %w", err)
	}
	return kept, nil
}

// importPreferences stores the values that differ from the stored ones, so a
// second import of the same file leaves every row as it was.
func importPreferences(ctx context.Context, tx *sql.Tx, prefs map[string]json.RawMessage) (int, error) {
	changes := make(map[string]json.RawMessage, len(prefs))
	for key, value := range prefs {
		var stored []byte
		err := tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key = ?", key).Scan(&stored)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return 0, fmt.Errorf("read preference %q: %w", key, err)
		}
		if err == nil && bytes.Equal(stored, value) {
			continue
		}
		changes[key] = value
	}
	if err := setPreferences(ctx, tx, changes); err != nil {
		return 0, err
	}
	return len(changes), nil
}
