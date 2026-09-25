package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
)

func (d *DB) Choice(ctx context.Context, itemID string) (progress.Choice, error) {
	var choice progress.Choice
	var audioLanguage, audioTitle, subtitleLanguage, subtitleTitle sql.NullString
	var subtitleOff bool
	err := d.db.QueryRowContext(ctx, `
		SELECT binge_group, audio_language, audio_title, subtitle_language, subtitle_title, subtitle_off
		FROM choices WHERE item_id = ?`, itemID).
		Scan(&choice.BingeGroup, &audioLanguage, &audioTitle, &subtitleLanguage, &subtitleTitle, &subtitleOff)
	if errors.Is(err, sql.ErrNoRows) {
		return progress.Choice{}, nil
	}
	if err != nil {
		return progress.Choice{}, fmt.Errorf("read choice for %q: %w", itemID, err)
	}
	if audioLanguage.Valid {
		choice.Audio = &progress.Track{Language: audioLanguage.String, Title: audioTitle.String}
	}
	if subtitleLanguage.Valid || subtitleOff {
		choice.Subtitle = &progress.Track{Language: subtitleLanguage.String, Title: subtitleTitle.String, Off: subtitleOff}
	}
	return choice, nil
}

func (d *DB) SaveChoice(ctx context.Context, itemID string, choice progress.Choice, at time.Time) error {
	var audioLanguage, audioTitle, subtitleLanguage, subtitleTitle sql.NullString
	var subtitleOff bool
	if a := choice.Audio; a != nil {
		audioLanguage = sql.NullString{String: a.Language, Valid: true}
		audioTitle = sql.NullString{String: a.Title, Valid: true}
	}
	if s := choice.Subtitle; s != nil {
		subtitleOff = s.Off
		if !s.Off {
			subtitleLanguage = sql.NullString{String: s.Language, Valid: true}
			subtitleTitle = sql.NullString{String: s.Title, Valid: true}
		}
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO choices(item_id, binge_group, audio_language, audio_title,
			subtitle_language, subtitle_title, subtitle_off, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(item_id) DO UPDATE SET
			binge_group = excluded.binge_group,
			audio_language = excluded.audio_language,
			audio_title = excluded.audio_title,
			subtitle_language = excluded.subtitle_language,
			subtitle_title = excluded.subtitle_title,
			subtitle_off = excluded.subtitle_off,
			updated_at = excluded.updated_at`,
		itemID, choice.BingeGroup, audioLanguage, audioTitle,
		subtitleLanguage, subtitleTitle, subtitleOff, at.Unix())
	if err != nil {
		return fmt.Errorf("save choice for %q: %w", itemID, err)
	}
	return nil
}
