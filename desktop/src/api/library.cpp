#include "library.h"

#include "core.h"

#include <QDateTime>
#include <QQmlEngine>
#include <algorithm>

MyList::MyList(Core *core, QObject *parent) : QObject(parent), m_core(core) { load(); }

void MyList::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
  load();
}

void MyList::setOrder(const QString &order) {
  if (order == m_order)
    return;
  m_order = order;
  emit changed();
}

void MyList::load() {
  const int asking = ++m_loading;
  // The shelf is asked at once and shown with the list, so the page does
  // not move under the pointer when it comes.
  auto fresh = std::make_shared<std::optional<QJsonArray>>();
  auto list = std::make_shared<std::optional<Core::Reply>>();
  auto show = [this, asking, fresh, list] {
    if (asking != m_loading || !fresh->has_value() || !list->has_value())
      return;
    const Core::Reply &reply = **list;
    if (!reply.ok()) {
      // A list already on screen stays: it is a reading again that failed.
      if (m_status == Ready)
        return;
      m_status = Failed;
      m_error = reply.message();
      emit changed();
      return;
    }
    const QJsonArray titles = reply.json()["items"].toArray();
    if (m_status == Ready && titles == m_titles && **fresh == m_fresh)
      return;
    m_titles = titles;
    m_fresh = **fresh;
    m_status = Ready;
    m_error.clear();
    emit changed();
  };
  m_core->get("/api/v1/new-episodes", {}, this, [fresh, show](const Core::Reply &reply) {
    *fresh = reply.ok() ? reply.json()["items"].toArray() : QJsonArray();
    show();
  });
  m_core->get("/api/v1/list", {}, this, [list, show](const Core::Reply &reply) {
    *list = reply;
    show();
  });
  if (m_status == Failed) {
    m_status = Loading;
    emit changed();
  }
}

static QString sortTitle(const QString &title) {
  const QString lower = title.trimmed().toLower();
  for (const QString article : {"the ", "a ", "an "})
    if (lower.startsWith(article) && lower.size() > article.size())
      return lower.mid(article.size());
  return lower;
}

QJsonArray MyList::sorted(const QJsonArray &titles, const QString &order) {
  QList<QJsonObject> list;
  for (const QJsonValue &t : titles)
    list.append(t.toObject());
  auto added = [](const QJsonObject &t) {
    return QDateTime::fromString(t["addedAt"].toString(), Qt::ISODate);
  };
  auto byAdded = [&](const QJsonObject &a, const QJsonObject &b) { return added(a) > added(b); };
  auto title = [](const QJsonObject &t) { return sortTitle(t["item"]["title"].toString()); };
  // Descending by [key], what has none last, ties to [then].
  auto by = [](auto key, auto then) {
    return [key, then](const QJsonObject &a, const QJsonObject &b) {
      const int x = key(a), y = key(b);
      if ((x == 0) != (y == 0))
        return y == 0;
      return x != y ? x > y : then(a, b);
    };
  };
  if (order == "title")
    std::stable_sort(list.begin(), list.end(), [&](const QJsonObject &a, const QJsonObject &b) {
      const int c = title(a).localeAwareCompare(title(b));
      return c != 0 ? c < 0 : byAdded(a, b);
    });
  else if (order == "year")
    std::stable_sort(list.begin(), list.end(),
                     by([](const QJsonObject &t) { return t["item"]["year"].toInt(); },
                        [&](const QJsonObject &a, const QJsonObject &b) {
                          return title(a).localeAwareCompare(title(b)) < 0;
                        }));
  else if (order == "rating")
    std::stable_sort(list.begin(), list.end(),
                     by([](const QJsonObject &t) { return t["rating"].toInt(); }, byAdded));
  else
    std::stable_sort(list.begin(), list.end(), byAdded);
  QJsonArray result;
  for (const QJsonObject &t : list)
    result.append(t);
  return result;
}

History::History(QObject *parent) : QAbstractListModel(parent) {
  m_undo.setInterval(5000);
  m_undo.setSingleShot(true);
  connect(&m_undo, &QTimer::timeout, this, &History::commit);
}

History::History(Core *core, QObject *parent) : History(parent) { m_core = core; }

History::~History() {
  // Told on the core's behalf, since this is going; nobody is left to put
  // the line back if it is refused.
  if (m_pending)
    forget(m_pending->line, m_core, [](bool) {});
}

void History::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
}

int History::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : int(m_lines.size());
}

QVariant History::data(const QModelIndex &index, int role) const {
  if (!index.isValid() || index.row() >= m_lines.size())
    return {};
  const QJsonObject &line = m_lines[index.row()];
  switch (role) {
  case ItemRole: return line["item"].toVariant();
  case EntryRole: return line["entry"].toVariant();
  case EpisodeRole: return line["episode"].toVariant();
  case RatingRole: return line["rating"].toInt();
  case DayRole:
    return QDateTime::fromString(line["entry"]["updatedAt"].toString(), Qt::ISODate)
        .toLocalTime()
        .date()
        .toString(Qt::ISODate);
  }
  return {};
}

QHash<int, QByteArray> History::roleNames() const {
  return {{ItemRole, "item"}, {EntryRole, "entry"}, {EpisodeRole, "episode"},
          {RatingRole, "rating"}, {DayRole, "day"}};
}

void History::setUndoTime(int ms) {
  if (ms == m_undo.interval())
    return;
  m_undo.setInterval(ms);
  emit undoTimeChanged();
}

void History::more() {
  if (m_loading || !m_more || !m_error.isEmpty())
    return;
  m_loading = true;
  emit stateChanged();
  QUrlQuery query{{"limit", QString::number(page)}};
  if (m_offset > 0)
    query.addQueryItem("offset", QString::number(m_offset));
  m_core->get("/api/v1/history", query, this, [this](const Core::Reply &reply) {
    m_loading = false;
    m_started = true;
    if (!reply.ok()) {
      m_error = reply.message();
      emit stateChanged();
      return;
    }
    const QJsonArray entries = reply.json()["entries"].toArray();
    if (!entries.isEmpty()) {
      beginInsertRows({}, int(m_lines.size()), int(m_lines.size() + entries.size() - 1));
      for (const QJsonValue &e : entries)
        m_lines.append(e.toObject());
      endInsertRows();
    }
    m_offset += int(entries.size());
    m_more = reply.json()["more"].toBool();
    emit stateChanged();
  });
}

void History::retry() {
  m_error.clear();
  more();
}

static bool same(const QJsonObject &a, const QJsonObject &b) {
  return a["item"]["id"] == b["item"]["id"] && a["entry"]["season"] == b["entry"]["season"] &&
         a["entry"]["episode"] == b["entry"]["episode"];
}

int History::find(const QJsonObject &line) const {
  for (int i = 0; i < m_lines.size(); ++i)
    if (same(m_lines[i], line))
      return i;
  return -1;
}

void History::insert(int at, const QJsonObject &line) {
  at = std::clamp(at, 0, int(m_lines.size()));
  beginInsertRows({}, at, at);
  m_lines.insert(at, line);
  endInsertRows();
}

void History::rate(int row, int score) {
  if (row < 0 || row >= m_lines.size())
    return;
  const QJsonObject line = m_lines[row];
  const int was = line["rating"].toInt();
  auto put = [this](const QJsonObject &line, int score) {
    const int at = find(line);
    if (at < 0)
      return;
    m_lines[at]["rating"] = score;
    emit dataChanged(index(at), index(at), {RatingRole});
  };
  put(line, score);
  const QString path = "/api/v1/ratings/" + Core::segment(line["item"]["id"].toString());
  const int season = line["entry"]["season"].toInt(), episode = line["entry"]["episode"].toInt();
  auto answer = [this, line, was, score, put](const Core::Reply &reply) {
    if (reply.ok())
      return;
    put(line, was);
    emit refused(score == 0 ? "clear" : "rate");
  };
  if (score == 0)
    m_core->send("DELETE", path,
                 {{"season", QString::number(season)}, {"episode", QString::number(episode)}},
                 QJsonValue::Undefined, this, answer);
  else
    m_core->send("PUT", path, {},
                 QJsonObject{{"season", season}, {"episode", episode}, {"rating", score}}, this,
                 answer);
}

void History::remove(int row) {
  if (row < 0 || row >= m_lines.size())
    return;
  // One undo at a time: the line before it goes now.
  if (m_pending)
    commit();
  beginRemoveRows({}, row, row);
  m_pending = Pending{m_lines.takeAt(row), row};
  endRemoveRows();
  m_undo.start();
  emit removingChanged();
}

void History::undo() {
  if (!m_pending)
    return;
  m_undo.stop();
  insert(m_pending->at, m_pending->line);
  m_pending.reset();
  emit removingChanged();
}

void History::commit() {
  if (!m_pending)
    return;
  m_undo.stop();
  const Pending gone = *m_pending;
  m_pending.reset();
  emit removingChanged();
  // The core's history is a line shorter from now, unless it refuses.
  --m_offset;
  forget(gone.line, this, [this, gone](bool ok) {
    if (ok)
      return;
    ++m_offset;
    insert(gone.at, gone.line);
    emit refused("remove");
  });
}

// What the line is, the position included: its place in Continue watching
// goes with it.
void History::forget(const QJsonObject &line, QObject *context, std::function<void(bool)> done) {
  m_core->send("DELETE", "/api/v1/progress/" + Core::segment(line["item"]["id"].toString()),
               {{"season", QString::number(line["entry"]["season"].toInt())},
                {"episode", QString::number(line["entry"]["episode"].toInt())}},
               QJsonValue::Undefined, context,
               [done](const Core::Reply &reply) { done(reply.ok()); });
}
