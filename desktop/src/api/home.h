#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QQmlParserStatus>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;

// One row of posters: a page of a catalogue at a time, or watch progress,
// which the core sends whole and in order. A catalogue shelf asks for
// nothing until its first more(), which the row calls once it is built.
class Shelf : public QAbstractListModel {
  Q_OBJECT
  QML_ELEMENT
  QML_UNCREATABLE("made by Home")
  // What names the shelf, which the page turns into words when it draws
  // it, so a change of language renames the shelves on screen. The
  // catalogue is the provider's id ("top", "year"), or "continue".
  Q_PROPERTY(QString kind READ kind CONSTANT)
  Q_PROPERTY(QString catalog READ catalog CONSTANT)
  Q_PROPERTY(QString genre READ genre CONSTANT)
  // Nothing came and nothing will: a genre nobody has titles for is not a
  // shelf.
  Q_PROPERTY(bool empty READ empty NOTIFY emptyChanged)

public:
  enum Role {
    ItemRole = Qt::UserRole,
    // Watch progress: the episode a card plays, and the share of it seen.
    SeasonRole,
    EpisodeRole,
    WatchedRole,
  };

  // A catalogue's shelf, [first] its first page when that is already here.
  Shelf(Core *core, const QJsonObject &row, const QString &genre, const QJsonArray &first,
        QObject *parent);
  // Watch progress, as the core answered it.
  Shelf(const QJsonArray &progress, QObject *parent);

  QString kind() const { return m_row["kind"].toString(); }
  QString catalog() const { return m_core ? m_row["id"].toString() : "continue"; }
  QString genre() const { return m_genre; }
  bool empty() const { return m_empty; }

  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  // Asks for the next page, unless one is on its way or the catalogue has
  // run out.
  Q_INVOKABLE void more();

signals:
  void emptyChanged();

private:
  void setEmpty(bool empty);

  Core *m_core = nullptr;
  QJsonObject m_row;
  QString m_genre;
  QJsonArray m_entries;
  bool m_loading = false;
  bool m_exhausted = false;
  bool m_empty = false;
};

// What Home shows: the hero picked from the first shelf's first page, the
// shelf that lies over the hero's foot, and the shelves under it.
class Home : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(Status status READ status NOTIFY changed)
  // Why the catalogues could not be listed.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  // A title from the catalogue row, which carries everything the banner
  // shows; empty when there is none to show.
  Q_PROPERTY(QVariantMap hero READ hero NOTIFY changed)
  // Watch progress when there is any, otherwise the shelf the hero came
  // from; none without a hero.
  Q_PROPERTY(Shelf *lead READ lead NOTIFY changed)
  Q_PROPERTY(QList<Shelf *> shelves READ shelves NOTIFY changed)

public:
  enum Status { Loading, Failed, Empty, Ready };
  Q_ENUM(Status)

  // The app's Core, from the engine that makes it.
  explicit Home(QObject *parent = nullptr) : QObject(parent) {}
  explicit Home(Core *core, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  Status status() const { return m_status; }
  QString error() const { return m_error; }
  QVariantMap hero() const { return m_hero.toVariantMap(); }
  Shelf *lead() const { return m_lead; }
  QList<Shelf *> shelves() const { return m_shelves; }

  // Lists the catalogues again, as Try again does.
  Q_INVOKABLE void load();

signals:
  void changed();

private:
  void settle();

  Core *m_core = nullptr;
  Status m_status = Loading;
  QString m_error;
  QJsonObject m_hero;
  Shelf *m_lead = nullptr;
  QList<Shelf *> m_shelves;

  // What a load is still waiting for, by load: a retry outruns the answers
  // of the load before it.
  int m_load = 0;
  bool m_progressHere = false;
  bool m_leadHere = false;
  QJsonArray m_progress;
  QList<QPair<QJsonObject, QString>> m_specs;
  QJsonArray m_leadPage;
};
