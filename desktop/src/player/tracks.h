#pragma once

#include "languages.h"
#include "rows.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QTemporaryDir>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <functional>

class Core;
class MpvItem;
class Preferences;

// The soundtrack and the subtitles of one film. mpv chooses by the languages
// it is told; a track picked by hand is kept for the title and, for
// subtitles, for the soundtrack's language; a subtitle the file lacks comes
// from those kept with the download or from the database, fetched by the
// core and handed to mpv as a file (decisions/subtitles.md).
class Tracks : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_UNCREATABLE("a Playback's")
  // The audio column: rows of track (its id), label, detail, current.
  Q_PROPERTY(Rows *audio READ audio CONSTANT)
  // The subtitle column: rows of kind ("off", "track", "found" or "note"),
  // track (the file's track id), found (where it is in the database's
  // answer), label, detail, current, more, group and indent. A language is one row, the file's own track when it
  // has one; the database's other copies sit behind its count.
  Q_PROPERTY(Rows *subtitles READ subtitles CONSTANT)
  // What the database lookup came to, under both columns; empty when it
  // found something or is still looking.
  Q_PROPERTY(QString note READ note NOTIFY changed)
  Q_PROPERTY(bool subtitlesOn READ subtitlesOn NOTIFY changed)
  Q_PROPERTY(double delay READ delay NOTIFY changed)
  Q_PROPERTY(double scale READ scale NOTIFY changed)
  Q_PROPERTY(double position READ position NOTIFY changed)
  Q_PROPERTY(QString background READ background NOTIFY changed)

public:
  Tracks(MpvItem *mpv, Core *core, Preferences *preferences, QObject *parent = nullptr);

  Rows *audio() const { return m_audioRows; }
  Rows *subtitles() const { return m_subtitleRows; }
  QString note() const { return m_note; }
  bool subtitlesOn() const;
  double delay() const;
  double scale() const { return m_scale; }
  double position() const { return m_position; }
  QString background() const { return m_background; }

  // Before the film opens: the title's picks, the files kept with the
  // download and the preferences are asked for once, then mpv is told how to
  // choose, and [ready] runs. Opening on defaults would show the wrong size
  // and languages.
  void prepare(const QString &itemId, const QString &downloadId, std::function<void()> ready);
  // mpv has the file: the title's picks can be matched against its tracks.
  void opened();
  // The file is opened again: the picks are matched again.
  void reopened();
  // The delay this copy was last watched with, from its progress.
  void restoreDelay(double seconds);
  // Whether the stored delay is known: until then a report carries none, or
  // the first one would wipe it.
  bool delayKnown() const { return m_delayKnown; }

  // The menu opened: the database is asked once, and the language whose
  // copy is on screen is unfolded.
  Q_INVOKABLE void show();
  Q_INVOKABLE void lookUp();
  Q_INVOKABLE void expand(const QString &group);
  Q_INVOKABLE void pickAudio(const QString &id);
  // An empty id turns subtitles off.
  Q_INVOKABLE void pickSubtitle(const QString &id);
  // A row of the database's: fetched by the core, then handed to mpv.
  Q_INVOKABLE void pickFound(int index);
  Q_INVOKABLE void setDelay(double seconds);
  Q_INVOKABLE void setScale(double scale);
  Q_INVOKABLE void setPosition(double position);
  Q_INVOKABLE void setBackground(const QString &background);

  // The mpv properties behind a subtitle background: "none" (the outline
  // alone), "shadow" or "box". mpv 0.38 gave the box `sub-border-style` and
  // made `sub-back-color` the shadow's colour; before it, `sub-back-color`
  // alone drew the box.
  static QVariantMap backgroundProperties(const QString &background, bool borderStyle);
  // [chosen]'s track id to turn on, "no" to turn it off, or empty to leave
  // mpv's choice, by the viewer's answer for the soundtrack's language: on
  // takes the file's track in the language [rank] puts first; off leaves a
  // forced track, which carries the lines not in the soundtrack's language.
  static QString subtitleForAudio(const QVariantList &tracks, bool on,
                                  const std::function<int(const QString &)> &rank);

signals:
  void changed();
  // A subtitle that was picked could not be fetched.
  void subtitleFailed();

private:
  void onTracks();
  void onTrackChange(const QString &property, const QString &value);
  // mpv reports values out of order and may coalesce changes made here, so
  // a change is the viewer's only when it is not one of ours or mpv's own.
  bool byViewer(const QString &property, const QString &value);
  void selectOwn(const QString &property, const QString &id);
  void apply();
  void matchTitles();
  void answerForAudio();
  void rememberForAudio(bool on);
  void saveTracks();
  void subtitleOnceChosen();
  void subtitleFromDatabase();
  void fetch(const QJsonObject &subtitle, std::function<void(const QString &path)> done);
  void addSubtitle(const QString &path, const QJsonObject &subtitle, const QString &flag);
  void rebuild();

  QVariantList tracksOf(const QString &type) const;
  QVariantMap selected(const QString &type) const;
  QString audioLanguage() const;
  QVariant answerForAudioLanguage() const;
  QString base(const QString &tag) const;
  QString trackLabel(const QVariantMap &track) const;
  bool isLoaded(const QJsonObject &subtitle) const;
  QVariantList embedded() const;
  Languages languages() const;

  QPointer<MpvItem> m_mpv;
  Core *m_core;
  Preferences *m_preferences;
  QString m_itemId;
  QString m_downloadId;
  bool m_prepared = false;
  bool m_opened = false;

  QJsonObject m_choice;
  QJsonArray m_kept;
  QJsonArray m_found;
  bool m_looking = false;
  bool m_lookedUp = false;
  bool m_lookupFailed = false;
  // What waits for the lookup in flight: the subtitle mpv did not find.
  std::function<void()> m_afterLookup;
  bool m_borderStyle = false;
  QString m_expanded;

  QSet<QString> m_titlesMatched;
  bool m_audioAnswered = false;
  bool m_databaseAsked = false;
  QHash<QString, QString> m_last;
  QSet<QString> m_mpvChoosing;
  QHash<QString, QString> m_own;
  QHash<QString, QString> m_unsaved;
  // The file of a subtitle this player added, until mpv lists it.
  QString m_ownFound;
  // The viewer's subtitle picks: a file that arrives after a later pick is
  // kept for next time, not put on screen.
  int m_picks = 0;

  // Fetched files by the core's address. mpv is handed the file, never the
  // address: while it waits on a silent provider, every command after it
  // waits too, the next episode's loadfile included.
  QTemporaryDir m_dir;
  QHash<QString, QString> m_paths;
  QHash<QString, QList<std::function<void(const QString &)>>> m_fetching;

  double m_scale = 1;
  double m_position = 100;
  QString m_background = "none";
  bool m_delayKnown = false;

  Rows *m_audioRows;
  Rows *m_subtitleRows;
  QString m_note;
};
