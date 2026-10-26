#pragma once

#include <QJsonArray>
#include <QObject>
#include <QQmlParserStatus>
#include <QStringList>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class Shelf;

// Search as one page: the word in the field, its titles as they are typed,
// and under an empty field the searches from before and what is popular.
// Films and series are asked at once and answered apart, so one provider
// timing out does not take the other's titles with it.
class Search : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  // The kind shown: "movie", "series", or empty for both.
  Q_PROPERTY(QString kind READ kind WRITE setKind NOTIFY changed)
  Q_PROPERTY(Status status READ status NOTIFY changed)
  // The word the titles on screen answer; until the next word's answer
  // arrives they stay, so the page does not blank between two keys.
  Q_PROPERTY(QString answered READ answered NOTIFY changed)
  // The answer's titles of the kind shown, the best match first.
  Q_PROPERTY(QVariantList results READ results NOTIFY changed)
  Q_PROPERTY(int films READ films NOTIFY changed)
  Q_PROPERTY(int series READ series NOTIFY changed)
  // What was searched for before, the latest first.
  Q_PROPERTY(QStringList recent READ recent NOTIFY recentChanged)
  // The catalogue's popular films, once search has been opened; null when
  // the catalogue has none.
  Q_PROPERTY(Shelf *popular READ popular NOTIFY popularChanged)
  // How long the field is left alone before its word is asked for: long
  // enough that a typed word is one search, short enough that the page
  // answers the keyboard. Tests shorten it.
  Q_PROPERTY(int wait READ wait WRITE setWait NOTIFY waitChanged)

public:
  // Idle: nothing in the field. Searching: the first word since is on its
  // way. Failed: neither kind answered, which is about the core, not the word.
  enum Status { Idle, Searching, Ready, Failed };
  Q_ENUM(Status)

  // The app's Core, from the engine that makes it.
  explicit Search(QObject *parent = nullptr);
  explicit Search(Core *core, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  QString query() const { return m_query; }
  void setQuery(const QString &query);
  QString kind() const { return m_kind; }
  void setKind(const QString &kind);
  Status status() const { return m_status; }
  QString answered() const { return m_answered; }
  QVariantList results() const;
  int films() const { return m_films; }
  int series() const { return m_series; }
  QStringList recent() const { return m_recent; }
  Shelf *popular() const { return m_popular; }
  int wait() const { return m_wait.interval(); }
  void setWait(int wait);

  // A fresh search: an empty field, both kinds, the searches from before
  // asked again, and the popular shelf the first time.
  Q_INVOKABLE void open();
  // Enter: the best match of the word in the field, as soon as it is here;
  // picked() says which.
  Q_INVOKABLE void submit();
  // The word in the field was gone through with: one of its titles opened.
  Q_INVOKABLE void remember();
  // Forgets one search, or every one when [query] is empty.
  Q_INVOKABLE void forget(const QString &query);
  // Asks for the word again, as Try again does.
  Q_INVOKABLE void retry();

  // The order titles are worth showing in. Each kind comes back in the
  // provider's order with no score to merge the two by, so the one
  // judgement made here is how much of the title the word is: the exact
  // name, then titles that begin with it, then those that carry it as a
  // word, then those that contain it somewhere. Inside a tier the
  // provider's order decides, and a tie goes to the film.
  static QJsonArray rank(const QString &query, const QJsonArray &films, const QJsonArray &series);

signals:
  void queryChanged();
  void changed();
  void recentChanged();
  void popularChanged();
  void waitChanged();
  // The title Enter asked for.
  void picked(const QVariantMap &item);

private:
  void ask();
  void show(const QString &word, const QJsonArray &ranked, bool failed);
  void pick();
  QString word() const { return m_query.trimmed(); }

  Core *m_core = nullptr;
  QString m_query;
  QString m_kind;
  Status m_status = Idle;
  QString m_answered;
  QJsonArray m_ranked;
  int m_films = 0;
  int m_series = 0;
  QTimer m_wait;
  // Which ask the answers on their way belong to: a later one outruns them.
  int m_asking = 0;
  bool m_submitted = false;
  // Answers already here, by the word lowercased; bounded, since deleting a
  // word letter by letter leaves one for every prefix.
  QHash<QString, QJsonArray> m_cache;
  QStringList m_cached;
  QStringList m_recent;
  Shelf *m_popular = nullptr;
  bool m_popularAsked = false;
};
