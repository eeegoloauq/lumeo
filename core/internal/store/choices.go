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
	var t trackColumns
	err := d.db.QueryRowContext(ctx, `
		SELECT binge_group, info_hash, folder, dir, picked, audio_language, audio_title, subtitle_language, subtitle_title, subtitle_off
		FROM choices WHERE item_id = ?`, itemID).
		Scan(&choice.BingeGroup, &choice.InfoHash, &choice.Folder, &choice.Dir, &choice.Picked, &t.audioLanguage, &t.audioTitle, &t.subtitleLanguage, &t.subtitleTitle, &t.subtitleOff)
	if errors.Is(err, sql.ErrNoRows) {
		return progress.Choice{}, nil
	}
	if err != nil {
		return progress.Choice{}, fmt.Errorf("read choice for %q: %w", itemID, err)
	}
	choice.Audio, choice.Subtitle = t.tracks()
	return choice, nil
}

func (d *DB) SaveChoice(ctx context.Context, itemID string, choice progress.Choice, at time.Time) error {
	t := columnsOf(choice.Audio, choice.Subtitle)
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO choices(item_id, binge_group, info_hash, folder, dir, picked, audio_language, audio_title,
			subtitle_language, subtitle_title, subtitle_off, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(item_id) DO UPDATE SET
			binge_group = excluded.binge_group,
			info_hash = excluded.info_hash,
			folder = excluded.folder,
			dir = excluded.dir,
			picked = excluded.picked,
			audio_language = excluded.audio_language,
			audio_title = excluded.audio_title,
			subtitle_language = excluded.subtitle_language,
			subtitle_title = excluded.subtitle_title,
			subtitle_off = excluded.subtitle_off,
			updated_at = excluded.updated_at`,
		itemID, choice.BingeGroup, choice.InfoHash, choice.Folder, choice.Dir, choice.Picked, t.audioLanguage, t.audioTitle,
		t.subtitleLanguage, t.subtitleTitle, t.subtitleOff, at.Unix())
	if err != nil {
		return fmt.Errorf("save choice for %q: %w", itemID, err)
	}
	return nil
}

// trackColumns are the picked tracks as the choices table keeps them: a NULL
// track is one nobody picked by hand, and subtitles turned off have no
// language.
type trackColumns struct {
	audioLanguage, audioTitle, subtitleLanguage, subtitleTitle sql.NullString
	subtitleOff                                                bool
}

func columnsOf(audio, subtitle *progress.Track) trackColumns {
	var t trackColumns
	if audio != nil {
		t.audioLanguage = sql.NullString{String: audio.Language, Valid: true}
		t.audioTitle = sql.NullString{String: audio.Title, Valid: true}
	}
	if subtitle != nil {
		t.subtitleOff = subtitle.Off
		if !subtitle.Off {
			t.subtitleLanguage = sql.NullString{String: subtitle.Language, Valid: true}
			t.subtitleTitle = sql.NullString{String: subtitle.Title, Valid: true}
		}
	}
	return t
}

// tracks reads the columns back; Choice and the personal export share it.
func (t trackColumns) tracks() (audio, subtitle *progress.Track) {
	if t.audioLanguage.Valid {
		audio = &progress.Track{Language: t.audioLanguage.String, Title: t.audioTitle.String}
	}
	if t.subtitleLanguage.Valid || t.subtitleOff {
		subtitle = &progress.Track{Language: t.subtitleLanguage.String, Title: t.subtitleTitle.String, Off: t.subtitleOff}
	}
	return audio, subtitle
}
