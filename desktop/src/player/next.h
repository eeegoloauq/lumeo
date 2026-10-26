#pragma once

#include <QDateTime>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class Downloads;
class MpvItem;
class Preferences;
class SourceChoice;

// What comes after this episode: which one it is, its download fetched ahead
// once this one is on disk, and the moment it is offered and taken. A file
// that names its ending offers it over the credits and goes on at its end; one
// that does not holds its last frame and counts down; the opening and an
// ending with a scene after it are skipped past instead (decisions/player.md).
class Next : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_UNCREATABLE("a Playback's")
  // The next episode as the catalogue has it; empty when there is none.
  Q_PROPERTY(QVariantMap episode READ episode NOTIFY changed)
  // Its download, once there is one.
  Q_PROPERTY(QVariantMap download READ download NOTIFY changed)
  // Why it has no download yet.
  Q_PROPERTY(Fetch fetch READ fetch NOTIFY changed)
  // What is offered over the picture now: "intro" or "ending" to skip, "next"
  // for the next episode's card; empty for nothing.
  Q_PROPERTY(QString offer READ offer NOTIFY offerChanged)
  // How far the offer has run, 0 to 1, the held last frame's countdown
  // included.
  Q_PROPERTY(double fill READ fill NOTIFY offerChanged)
  // Seconds until the next episode starts by itself; -1 when it waits for a
  // press.
  Q_PROPERTY(int secondsLeft READ secondsLeft NOTIFY offerChanged)
  // Another episode is starting: the picture waits for it.
  Q_PROPERTY(bool advancing READ advancing NOTIFY changed)
  // What is starting it, for its failures.
  Q_PROPERTY(SourceChoice *choice READ choice NOTIFY changed)
  // The episode starting, {season, number, title}; empty for none.
  Q_PROPERTY(QVariantMap starting READ starting NOTIFY changed)
  // How long a second is here, and how long a prefetch that failed waits:
  // tests shorten both.
  Q_PROPERTY(int second MEMBER second)
  Q_PROPERTY(int prefetchRetry MEMBER prefetchRetry)

public:
  enum Fetch { Waiting, Off, NoRoom, NoCopy, Failed };
  Q_ENUM(Fetch)

  Next(MpvItem *mpv, Core *core, Preferences *preferences, Downloads *downloads,
       QObject *parent = nullptr);

  QVariantMap episode() const { return m_episode; }
  QVariantMap download() const;
  Fetch fetch() const { return m_fetch; }
  QString offer() const { return m_offer; }
  double fill() const { return m_fill; }
  int secondsLeft() const { return m_secondsLeft; }
  bool advancing() const { return m_advancing; }
  SourceChoice *choice() const { return m_choice; }
  QVariantMap starting() const { return m_starting; }

  // The download playing, as the core last described it: on every poll, so
  // that a prefetch that failed is asked for again once its wait is over.
  void update(const QVariantMap &download);
  // mpv has the file.
  void opened() { m_opened = true; }

  // The pill: past the opening or the ending.
  Q_INVOKABLE void skip();
  // The card, the button, or the countdown run out.
  Q_INVOKABLE void advance();
  // Another episode of the title, from the episodes panel.
  Q_INVOKABLE void play(const QVariantMap &episode);
  // The panel's Download now and Download anyway: the prefetch without the
  // disk-limit check.
  Q_INVOKABLE void downloadNow() { fetchNext(false); }
  // Asks again for what is starting, after it failed.
  Q_INVOKABLE void retry();

  int second = 1000;
  int prefetchRetry = 30000;

  // The rules, without an mpv. Chapters are mpv's list, [{time, title}].
  // The opening a file names; never inferred from time, or a cold start
  // would be skipped. -1 for none.
  static int openingChapter(const QVariantList &chapters);
  // The start of the last run of ending and preview chapters; -1 for none.
  static int endingChapter(const QVariantList &chapters);
  // The first chapter after the ending run from [start]; -1 when it lasts to
  // the end of the file.
  static int afterEnding(const QVariantList &chapters, int start);
  // Past the start of the ending the file names: watched, even before the
  // core's 90%, since an anime's ending and preview start at 87%.
  static bool inCredits(const QVariantList &chapters, double position);

  struct Moment {
    QString action; // "intro", "ending", "next", or empty for none
    double start = 0;
    double end = 0;
    double fill = 0;
    // The file named this interval; an unnamed end holds its last frame.
    bool credits = true;
  };
  // What is offered at [position]. [notice] is how long before an end the
  // file does not name the next episode is offered; zero, only once it ends.
  static Moment moment(const QVariantList &chapters, double position, double duration,
                       bool hasNext, double notice);

signals:
  void changed();
  void offerChanged();
  // Its position counts as watched: the core is told before it goes.
  void watched();
  // The next download to play, in the same sitting.
  void next(const QString &downloadId);

private:
  void lookUp();
  void prefetch();
  void fetchNext(bool prefetch);
  void onEnded();
  void recompute();
  double grace() const;
  double notice() const;

  QPointer<MpvItem> m_mpv;
  Core *m_core;
  Preferences *m_preferences;
  Downloads *m_downloads;
  QVariantMap m_playing;
  bool m_opened = false;

  QVariantMap m_episode;
  bool m_asked = false;
  bool m_prefetchAsked = false;
  QDateTime m_prefetchAgainAt;
  Fetch m_fetch = Waiting;
  SourceChoice *m_fetching = nullptr;

  QString m_offer;
  double m_fill = 0;
  int m_secondsLeft = -1;
  double m_target = 0;

  // The file ended and holds its last frame; when, and where it stood.
  QDateTime m_endedAt;
  double m_endedPosition = 0;
  double m_offerStart = 0;
  // The end came before the next episode was known.
  bool m_fileEnded = false;
  QTimer m_countdown;

  bool m_advancing = false;
  SourceChoice *m_choice = nullptr;
  QVariantMap m_starting;
};
