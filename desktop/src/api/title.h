#pragma once

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QQmlParserStatus>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class Downloads;

// One title's page: the title from the catalogue and how far it was watched.
class Title : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(QString itemId READ itemId WRITE setItemId NOTIFY itemIdChanged)
  Q_PROPERTY(Status status READ status NOTIFY changed)
  Q_PROPERTY(QString error READ error NOTIFY changed)
  Q_PROPERTY(QVariantMap item READ item NOTIFY changed)
  // How far it was watched, as the core keeps it: {entries, next, upcoming}.
  Q_PROPERTY(QVariantMap progress READ progress NOTIFY changed)
  // The episode the page opens on, {season, episode}: the one to play next,
  // else the one a caught-up series goes on with, else the last one
  // watched; empty for a title never watched.
  Q_PROPERTY(QVariantMap opening READ opening NOTIFY changed)
  // A season's download is being asked for, one episode at a time.
  Q_PROPERTY(bool queueing READ queueing NOTIFY queueingChanged)
  // The link the title is shared by; empty without an IMDb id, which names
  // it the same on every machine.
  Q_PROPERTY(QString link READ link NOTIFY changed)

public:
  enum Status { Loading, Failed, Ready };
  Q_ENUM(Status)

  explicit Title(QObject *parent = nullptr) : QObject(parent) {}
  Title(Core *core, Downloads *downloads, const QString &itemId, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  QString itemId() const { return m_itemId; }
  void setItemId(const QString &itemId);
  Status status() const { return m_status; }
  QString error() const { return m_error; }
  QVariantMap item() const { return m_item.toVariantMap(); }
  QVariantMap progress() const { return m_progress.toVariantMap(); }
  QVariantMap opening() const;
  bool queueing() const { return m_queueing; }
  QString link() const;

  // Where shared links point: a page anyone can open, whose Open button
  // hands lumeo://title/<kind>/<imdb> to an installed Lumeo (site/).
  static const QString sharePage;
  // The desktop has no share sheet to hand the link to; the person pastes
  // it wherever they talk.
  Q_INVOKABLE void copyLink() const;

  Q_INVOKABLE void load();
  // Downloads, for each of [episodes] ({season, number}) without a download
  // yet, the copy Play would start. One at a time: a provider asked for
  // seventeen lists at once answers 403. An episode nobody has a copy of is
  // passed over.
  Q_INVOKABLE void downloadSeason(const QVariantList &episodes);

signals:
  void itemIdChanged();
  void changed();
  void queueingChanged();
  // The season's download stopped: the core did not answer, or a provider
  // refused while it listed nothing, and the rest would fail the same way.
  void seasonFailed(const QString &reason);

private:
  void queueNext();
  void stopQueue(const QString &reason);

  Core *m_core = nullptr;
  Downloads *m_downloads = nullptr;
  QVariantList m_queue;
  bool m_queueing = false;
  QString m_itemId;
  Status m_status = Loading;
  QString m_error;
  QJsonObject m_item;
  QJsonObject m_progress;
  int m_load = 0;
};

// The choice of how to watch one film or episode: which copies exist, which
// one Play starts, and Play itself. One object, because the button sits in
// the banner and the copies in a drawer over the page, and the player lists
// the same ones.
class SourceChoice : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(QString itemId MEMBER m_itemId WRITE setItemId NOTIFY keyChanged)
  Q_PROPERTY(int season MEMBER m_season WRITE setSeason NOTIFY keyChanged)
  Q_PROPERTY(int episode MEMBER m_episode WRITE setEpisode NOTIFY keyChanged)
  // The air date the provider gave, ISO 8601, which decides what an empty
  // list means; empty when there is none.
  Q_PROPERTY(QString released READ released WRITE setReleased NOTIFY keyChanged)
  // Play was pressed before there was anything to play: honoured as soon as
  // the list arrives. Also how Play on the home screen's banner carries over.
  Q_PROPERTY(bool startWhenReady MEMBER m_startWhenReady NOTIFY changed)

  Q_PROPERTY(QVariantList sources READ sources NOTIFY changed)
  // The providers that refused or did not answer: {provider, reason, status}.
  Q_PROPERTY(QVariantList failed READ failed NOTIFY changed)
  // How many source addons the core asked.
  Q_PROPERTY(int providers READ providers NOTIFY changed)
  // The copy Play starts, as an index into sources; -1 for none.
  Q_PROPERTY(int picked READ picked NOTIFY changed)
  Q_PROPERTY(bool listed READ listed NOTIFY changed)
  Q_PROPERTY(bool loading READ loading NOTIFY changed)
  Q_PROPERTY(bool starting READ starting NOTIFY changed)
  // Play was asked for and has not happened yet.
  Q_PROPERTY(bool pending READ pending NOTIFY changed)
  // Play has something to start, or will once the list arrives.
  Q_PROPERTY(bool playable READ playable NOTIFY changed)
  // Not out yet: nobody has a copy, so nobody is asked.
  Q_PROPERTY(bool upcoming READ upcoming NOTIFY changed)
  // No provider can be asked for a copy: none is added, or none answered.
  // Only what is on disk plays.
  Q_PROPERTY(bool unreachable READ unreachable NOTIFY changed)
  // Why the last request failed: the HTTP status, 0 when the core did not
  // answer, -1 when nothing failed.
  Q_PROPERTY(int errorStatus READ errorStatus NOTIFY changed)
  Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY changed)
  // A copy the disk has no room for: {size, free} in bytes; else empty.
  Q_PROPERTY(QVariantMap noRoom READ noRoom NOTIFY changed)
  // Why a list came back empty, for the line under Play: "addons" (none is
  // added), "failed" (a provider refused or did not answer), "today",
  // "yesterday" (out, no copies yet), "none"; empty while it is not empty.
  Q_PROPERTY(QString empty READ empty NOTIFY changed)
  // The title's releases on disk, as loadFolders() last found them:
  // {source, folder, dir, episodes, directorsCut, current}.
  Q_PROPERTY(QVariantList folders READ folders NOTIFY foldersChanged)
  // A release was picked by hand; false while Play takes the best copy of
  // each episode.
  Q_PROPERTY(bool chosen READ chosen NOTIFY foldersChanged)

public:
  explicit SourceChoice(QObject *parent = nullptr) : QObject(parent) {}
  SourceChoice(Core *core, Downloads *downloads, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  void setItemId(const QString &itemId);
  void setSeason(int season);
  void setEpisode(int episode);
  QString released() const;
  void setReleased(const QString &released);

  QVariantList sources() const { return m_sources.toVariantList(); }
  QVariantList failed() const { return m_failed.toVariantList(); }
  int providers() const { return m_providers; }
  int picked() const { return m_picked; }
  bool listed() const { return m_listed; }
  bool loading() const { return m_loading; }
  bool starting() const { return m_starting; }
  bool pending() const { return m_starting || m_startWhenReady; }
  bool playable() const { return m_loading || m_picked >= 0; }
  bool upcoming() const;
  bool unreachable() const {
    return m_listed && (m_providers == 0 || m_failed.size() >= m_providers);
  }
  int errorStatus() const { return m_errorStatus; }
  QString errorMessage() const { return m_errorMessage; }
  QVariantMap noRoom() const;
  QString empty() const;
  QVariantList folders() const { return m_folders.toVariantList(); }
  bool chosen() const { return m_chosen; }

  // Asks for the list again. [follow]: Play takes the copy of the release
  // just picked, which the core marks, over the ranking's best.
  Q_INVOKABLE void load(bool follow = false);
  // Asks the core which releases of the title are on disk; a download may
  // have finished since the last look.
  Q_INVOKABLE void loadFolders();
  // Makes the release of copy [index] the title's, which the next episode
  // goes on from; [play] starts it once the list is asked again.
  Q_INVOKABLE void choose(int index, bool play = false);
  // The same for release [index] on disk.
  Q_INVOKABLE void chooseFolder(int index);
  // Back to the best copy of each episode.
  Q_INVOKABLE void chooseBest();
  // Makes a folder on this machine, or a film's file, the title's copies.
  Q_INVOKABLE void link(const QString &path);
  // Plays the copy picked, or the one on disk while the list is coming, or
  // holds the press until the list is here.
  Q_INVOKABLE void start();
  // The same copy Play would start, fetched without opening the player.
  Q_INVOKABLE void download();

  // What now is, for the empty line and whether an episode is out; tests
  // set it.
  QDateTime clock;

signals:
  void keyChanged();
  void changed();
  // Play started this download: watching begins here, before the file exists.
  void started(const QString &downloadId);
  void foldersChanged();
  // A pick the core refused, in its words; 422 is a folder with nothing of
  // the title in it.
  void refused(const QString &reason, int status);

private:
  QDateTime now() const { return clock.isValid() ? clock : QDateTime::currentDateTimeUtc(); }
  // Another title or episode: its list, and a Play held for the one before
  // is not for this one.
  void rekey();
  void reload();
  void begin(bool play);
  // The first copy this machine decodes, by the codecs its name states.
  int decodable() const;
  // The download on disk Play can open without asking anybody; empty when
  // there is none, or when another copy of it is arriving, which a pick
  // put first.
  QString onDisk() const;
  // Records [source] (null for the best copy) as the title's release, then
  // lists the copies again.
  void record(const QJsonValue &source, bool play);

  Core *m_core = nullptr;
  Downloads *m_downloads = nullptr;
  QJsonArray m_folders;
  bool m_chosen = false;
  bool m_complete = false;
  bool m_reloadQueued = false;
  int m_load = 0;

  QString m_itemId;
  int m_season = 0;
  int m_episode = 0;
  QDateTime m_released;
  bool m_startWhenReady = false;

  QJsonArray m_sources;
  QJsonArray m_failed;
  int m_providers = 0;
  int m_picked = -1;
  bool m_listed = false;
  bool m_loading = false;
  bool m_starting = false;
  int m_errorStatus = -1;
  QString m_errorMessage;
  QJsonObject m_errorBody;
};
