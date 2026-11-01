#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <optional>

class Core;

// My list as the page shows it: the titles of the stage and kind chosen in
// the order chosen, and the followed series with new episodes and with
// episodes coming up as shelves over them (decisions/library.md).
class MyList : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(Status status READ status NOTIFY changed)
  // Why the list could not be read.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  // One of LocalSettings' list orders.
  Q_PROPERTY(QString order READ order WRITE setOrder NOTIFY changed)
  // How far the viewer is into what is shown: "all", "toWatch" (nothing of
  // it played), "watching" or "watched" (a film watched, a series caught up
  // with).
  Q_PROPERTY(QString stage READ stage WRITE setStage NOTIFY changed)
  // "" for both kinds, "movie" or "series".
  Q_PROPERTY(QString kind READ kind WRITE setKind NOTIFY changed)
  // The titles of [stage] and [kind] in [order], each the core's listed title.
  Q_PROPERTY(QVariantList titles READ titles NOTIFY changed)
  // How many are on the list whatever is shown: an empty list and an empty
  // stage say different things.
  Q_PROPERTY(int total READ total NOTIFY changed)
  // A shelf over the list, not the list: a core that cannot work them out
  // still shows what is on it.
  Q_PROPERTY(QVariantList fresh READ fresh NOTIFY changed)
  // The followed series' episodes dated ahead, soonest first; a shelf too.
  Q_PROPERTY(QVariantList comingUp READ comingUp NOTIFY changed)

public:
  enum Status { Loading, Ready, Failed };
  Q_ENUM(Status)

  explicit MyList(QObject *parent = nullptr) : QObject(parent) {}
  explicit MyList(Core *core, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  Status status() const { return m_status; }
  QString error() const { return m_error; }
  QString order() const { return m_order; }
  void setOrder(const QString &order);
  QString stage() const { return m_stage; }
  void setStage(const QString &stage);
  QString kind() const { return m_kind; }
  void setKind(const QString &kind);
  QVariantList titles() const {
    return sorted(filtered(m_titles, m_stage, m_kind), m_order).toVariantList();
  }
  int total() const { return int(m_titles.size()); }
  QVariantList fresh() const { return m_fresh.toVariantList(); }
  QVariantList comingUp() const { return m_comingUp.toVariantList(); }

  // Reads both again, keeping what is shown until the answers are here: a
  // title page opened from the list may have changed it.
  Q_INVOKABLE void load();

  // Titles compare without a leading article, the way a shelf of films is
  // alphabetised; what has no year or no score goes to the end of an order
  // by year or score.
  static QJsonArray sorted(const QJsonArray &titles, const QString &order);
  // The titles of [stage] and [kind], as the properties name them.
  static QJsonArray filtered(const QJsonArray &titles, const QString &stage, const QString &kind);
  // A listed title's stage: "toWatch", "watching" or "watched".
  static QString stageOf(const QJsonObject &listed);

signals:
  void changed();

private:
  Core *m_core = nullptr;
  Status m_status = Loading;
  QString m_error;
  QString m_order = "added";
  QString m_stage = "all";
  QString m_kind;
  QJsonArray m_titles;
  QJsonArray m_fresh;
  QJsonArray m_comingUp;
  // Which load the answers on their way belong to.
  int m_loading = 0;
};

// What was watched, the latest first, as far as it has been read: fifty
// lines a page, read the first time History is shown and then as its end
// comes near. Taking a line out forgets where it was left; it waits a few
// seconds for an undo before the core is told.
class History : public QAbstractListModel, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)
  // The first page has been asked for and answered, or refused.
  Q_PROPERTY(bool started READ started NOTIFY stateChanged)
  // Why the last page did not come; the next waits for retry().
  Q_PROPERTY(QString error READ error NOTIFY stateChanged)
  // A line taken out that undo() still brings back.
  Q_PROPERTY(bool removing READ removing NOTIFY removingChanged)
  // How long undo() is offered. Tests shorten it.
  Q_PROPERTY(int undoTime READ undoTime WRITE setUndoTime NOTIFY undoTimeChanged)

public:
  enum Role {
    ItemRole = Qt::UserRole,
    EntryRole,
    // The catalogue's episode, or undefined for a film.
    EpisodeRole,
    // The viewer's score of what the line is about, 0 when none.
    RatingRole,
    // The day it was watched on this machine's calendar, "2026-10-26": the
    // page's sections.
    DayRole,
  };

  static constexpr int page = 50;

  explicit History(QObject *parent = nullptr);
  explicit History(Core *core, QObject *parent = nullptr);
  // A line still waiting for its undo is taken out now.
  ~History() override;

  void classBegin() override {}
  void componentComplete() override;

  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  bool loading() const { return m_loading; }
  bool started() const { return m_started; }
  QString error() const { return m_error; }
  bool removing() const { return m_pending.has_value(); }
  int undoTime() const { return m_undo.interval(); }
  void setUndoTime(int ms);

  // The next page, unless one is on its way, there is no more, or the last
  // one failed.
  Q_INVOKABLE void more();
  Q_INVOKABLE void retry();
  // Scores what line [row] is about: the episode for a series, the film
  // otherwise; 0 takes the score off. The line changes at once and goes
  // back if the core refuses.
  Q_INVOKABLE void rate(int row, int score);
  Q_INVOKABLE void remove(int row);
  Q_INVOKABLE void undo();

signals:
  void stateChanged();
  void removingChanged();
  void undoTimeChanged();
  // What did not take: "rate", "clear" or "remove".
  void refused(const QString &what);

private:
  struct Pending {
    QJsonObject line;
    int at;
  };

  int find(const QJsonObject &line) const;
  void insert(int at, const QJsonObject &line);
  void commit();
  void forget(const QJsonObject &line, QObject *context, std::function<void(bool)> done);

  Core *m_core = nullptr;
  QList<QJsonObject> m_lines;
  bool m_loading = false;
  bool m_started = false;
  bool m_more = true;
  QString m_error;
  // Where the next page starts on the core's side: the lines read, less
  // those the core has since forgotten.
  int m_offset = 0;
  std::optional<Pending> m_pending;
  QTimer m_undo;
};
