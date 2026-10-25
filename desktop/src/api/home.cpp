#include "home.h"

#include "core.h"

#include <QQmlEngine>
#include <QRandomGenerator>
#include <QSet>
#include <QUrlQuery>

namespace {

// The shelves worth a home screen, in order. The page names them: five
// provider rows called "Popular" and "New" say nothing.
const QStringList worthAShelf{"movie/top", "series/top", "movie/imdbRating", "movie/year",
                              "series/imdbRating"};

QUrlQuery pageOf(const QJsonObject &row, const QString &genre, qsizetype skip) {
  QUrlQuery query{{"provider", row["providerId"].toString()},
                  {"kind", row["kind"].toString()},
                  {"id", row["id"].toString()}};
  if (!genre.isEmpty())
    query.addQueryItem("genre", genre);
  if (skip > 0)
    query.addQueryItem("skip", QString::number(skip));
  return query;
}

} // namespace

Shelf::Shelf(Core *core, const QJsonObject &row, const QString &genre, const QJsonArray &first,
             QObject *parent)
    : QAbstractListModel(parent), m_core(core), m_row(row), m_genre(genre), m_entries(first) {}

Shelf::Shelf(const QJsonArray &progress, QObject *parent)
    : QAbstractListModel(parent), m_entries(progress), m_exhausted(true) {}

int Shelf::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : int(m_entries.size());
}

QVariant Shelf::data(const QModelIndex &index, int role) const {
  const QJsonObject entry = m_entries.at(index.row()).toObject();
  const QJsonObject next = entry["next"].toObject();
  switch (role) {
  case ItemRole: return (m_core ? entry : entry["item"].toObject()).toVariantMap();
  case SeasonRole: return m_core ? QVariant() : next["season"].toInt();
  case EpisodeRole: return m_core ? QVariant() : next["episode"].toInt();
  case WatchedRole: {
    if (m_core)
      return {};
    const double duration = next["duration"].toDouble();
    return duration > 0 ? std::clamp(next["position"].toDouble() / duration, 0.0, 1.0) : 0.0;
  }
  }
  return {};
}

QHash<int, QByteArray> Shelf::roleNames() const {
  return {{ItemRole, "item"}, {SeasonRole, "season"}, {EpisodeRole, "episode"},
          {WatchedRole, "watched"}};
}

void Shelf::more() {
  if (!m_core || m_loading || m_exhausted)
    return;
  m_loading = true;
  m_core->get("/api/v1/catalog", pageOf(m_row, m_genre, m_entries.size()), this,
              [this](const Core::Reply &reply) {
                m_loading = false;
                // A failed page is not the end of the shelf: the next scroll
                // asks again. Only a shelf with nothing at all steps aside, so
                // a dead genre does not pulse forever.
                if (!reply.ok()) {
                  setEmpty(m_entries.isEmpty());
                  return;
                }
                QSet<QString> known;
                for (const QJsonValue &item : std::as_const(m_entries))
                  known.insert(item["id"].toString());
                QJsonArray fresh;
                for (const QJsonValue &item : reply.json()["items"].toArray())
                  if (!known.contains(item["id"].toString())) {
                    known.insert(item["id"].toString());
                    fresh.append(item);
                  }
                // Providers repeat their last page once they run out, so a
                // page that adds nothing new is the end of the shelf.
                if (fresh.isEmpty()) {
                  m_exhausted = true;
                  setEmpty(m_entries.isEmpty());
                  return;
                }
                const int first = int(m_entries.size());
                beginInsertRows({}, first, first + int(fresh.size()) - 1);
                for (const QJsonValue &item : std::as_const(fresh))
                  m_entries.append(item);
                endInsertRows();
              });
}

void Shelf::setEmpty(bool empty) {
  if (empty == m_empty)
    return;
  m_empty = empty;
  emit emptyChanged();
}

Home::Home(Core *core, QObject *parent) : QObject(parent), m_core(core) { load(); }

void Home::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
  load();
}

void Home::load() {
  const int load = ++m_load;
  m_status = Loading;
  m_error.clear();
  m_progressHere = m_leadHere = false;
  m_progress = {};
  m_specs.clear();
  m_leadPage = {};
  emit changed();

  // Watch progress is local: a catalogue the core cannot fetch does not take
  // it off the page, and progress that fails takes nothing with it.
  m_core->get("/api/v1/continue", {{"limit", "30"}}, this,
              [this, load](const Core::Reply &reply) {
                if (load != m_load)
                  return;
                m_progress = reply.ok() ? reply.json().toArray() : QJsonArray();
                m_progressHere = true;
                settle();
              });
  m_core->get("/api/v1/catalogs", {}, this, [this, load](const Core::Reply &reply) {
    if (load != m_load)
      return;
    if (!reply.ok()) {
      ++m_load;
      m_status = Failed;
      m_error = reply.message();
      emit changed();
      return;
    }
    QHash<QString, QJsonObject> rows;
    for (const QJsonValue &row : reply.json()["catalogs"].toArray())
      rows.insert(row["kind"].toString() + "/" + row["id"].toString(), row.toObject());
    for (const QString &key : worthAShelf)
      if (rows.contains(key))
        m_specs.append({rows[key], QString()});
    // Depth comes from the genres the provider's catalogue accepts.
    for (const auto &[key, limit] : {std::pair{"movie/top", 14}, std::pair{"series/top", 8}}) {
      const QJsonArray genres = rows.value(key)["genres"].toArray();
      for (qsizetype i = 0; i < std::min<qsizetype>(limit, genres.size()); ++i)
        m_specs.append({rows[key], genres[i].toString()});
    }
    if (m_specs.isEmpty()) {
      m_leadHere = true;
      settle();
      return;
    }
    m_core->get("/api/v1/catalog", pageOf(m_specs.first().first, m_specs.first().second, 0), this,
                [this, load](const Core::Reply &page) {
                  if (load != m_load)
                    return;
                  // The shelf says for itself what it could not load.
                  m_leadPage = page.ok() ? page.json()["items"].toArray() : QJsonArray();
                  m_leadHere = true;
                  settle();
                });
  });
}

void Home::settle() {
  if (!m_progressHere || !m_leadHere)
    return;
  // QML may still be drawing the shelves of the load before.
  for (Shelf *shelf : std::as_const(m_shelves))
    shelf->deleteLater();
  if (m_lead)
    m_lead->deleteLater();

  QJsonArray rest = m_leadPage;
  m_hero = {};
  if (!rest.isEmpty()) {
    // Never the title that opens the shelf underneath: the same poster twice
    // in a row reads as a bug even when it is not one.
    const qsizetype from = rest.size() > 1 ? 1 : 0;
    const int choices = int(std::min<qsizetype>(10, rest.size() - from));
    const qsizetype pick = from + QRandomGenerator::global()->bounded(choices);
    m_hero = rest.takeAt(pick).toObject();
  }
  QList<Shelf *> catalogue;
  for (qsizetype i = 0; i < m_specs.size(); ++i)
    catalogue.append(new Shelf(m_core, m_specs[i].first, m_specs[i].second,
                               i == 0 ? rest : QJsonArray(), this));
  Shelf *progress = m_progress.isEmpty() ? nullptr : new Shelf(m_progress, this);

  // A title part-way through is content, and goes first
  // (decisions/interface.md).
  if (!m_hero.isEmpty()) {
    m_lead = progress ? progress : catalogue.takeFirst();
    m_shelves = catalogue;
  } else {
    m_lead = nullptr;
    m_shelves = catalogue;
    if (progress)
      m_shelves.prepend(progress);
  }
  m_status = m_shelves.isEmpty() && !m_lead ? Empty : Ready;
  emit changed();
}
