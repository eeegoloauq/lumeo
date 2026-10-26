#include "search.h"

#include "core.h"
#include "home.h"

#include <QJsonObject>
#include <QQmlEngine>
#include <QUrlQuery>
#include <algorithm>
#include <memory>

namespace {

// Bounded: deleting a word letter by letter leaves an answer for every prefix.
constexpr qsizetype cacheLimit = 40;

// A title reduced to the word somebody would say it by: without the leading
// article a catalogue files it under.
QString plain(const QString &text) {
  const QString trimmed = text.trimmed().toLower();
  for (const QString article : {"the ", "a ", "an "})
    if (trimmed.startsWith(article))
      return trimmed.mid(article.size());
  return trimmed;
}

} // namespace

Search::Search(QObject *parent) : QObject(parent) {
  m_wait.setSingleShot(true);
  m_wait.setInterval(220);
  connect(&m_wait, &QTimer::timeout, this, &Search::ask);
}

Search::Search(Core *core, QObject *parent) : Search(parent) { m_core = core; }

void Search::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
}

void Search::setWait(int wait) {
  if (wait == m_wait.interval())
    return;
  m_wait.setInterval(wait);
  emit waitChanged();
}

void Search::setQuery(const QString &query) {
  if (query == m_query)
    return;
  m_query = query;
  emit queryChanged();

  m_wait.stop();
  // Whatever is on its way answers a word no longer in the field.
  ++m_asking;
  m_submitted = false;
  if (word().isEmpty()) {
    m_status = Idle;
    m_answered.clear();
    m_ranked = {};
    m_films = m_series = 0;
    emit changed();
    return;
  }
  const auto cached = m_cache.constFind(word().toLower());
  if (cached != m_cache.constEnd()) {
    show(word(), *cached, false);
    return;
  }
  if (m_status == Idle) {
    m_status = Searching;
    emit changed();
  }
  m_wait.start();
}

void Search::setKind(const QString &kind) {
  if (kind == m_kind)
    return;
  m_kind = kind;
  emit changed();
}

QVariantList Search::results() const {
  QVariantList results;
  for (const QJsonValue &item : m_ranked)
    if (m_kind.isEmpty() || item["kind"].toString() == m_kind)
      results.append(item.toObject().toVariantMap());
  return results;
}

void Search::ask() {
  const QString wanted = word();
  if (wanted.isEmpty() || !m_core)
    return;
  m_wait.stop();
  const int asking = ++m_asking;
  struct Answers {
    QJsonArray films, series;
    int answered = 0, failed = 0;
  };
  auto answers = std::make_shared<Answers>();
  for (const QString kind : {"movie", "series"})
    m_core->get("/api/v1/search", QUrlQuery{{"q", wanted}, {"kind", kind}}, this,
                [this, wanted, kind, asking, answers](const Core::Reply &reply) {
                  if (asking != m_asking)
                    return;
                  if (!reply.ok())
                    ++answers->failed;
                  else
                    (kind == "movie" ? answers->films : answers->series) =
                        reply.json()["items"].toArray();
                  if (++answers->answered < 2)
                    return;
                  const QJsonArray ranked = rank(wanted, answers->films, answers->series);
                  // A half answer is not kept, or the provider that failed
                  // would never be asked again for this word.
                  if (answers->failed == 0) {
                    if (m_cached.size() >= cacheLimit)
                      m_cache.remove(m_cached.takeFirst());
                    m_cache.insert(wanted.toLower(), ranked);
                    m_cached.append(wanted.toLower());
                  }
                  show(wanted, ranked, answers->failed == 2);
                });
}

void Search::show(const QString &word, const QJsonArray &ranked, bool failed) {
  m_answered = word;
  m_ranked = failed ? QJsonArray() : ranked;
  m_films = int(std::count_if(m_ranked.begin(), m_ranked.end(), [](const QJsonValue &item) {
    return item["kind"].toString() != "series";
  }));
  m_series = int(m_ranked.size()) - m_films;
  m_status = failed ? Failed : Ready;
  emit changed();
  if (m_submitted)
    pick();
}

void Search::pick() {
  m_submitted = false;
  const QVariantList shown = results();
  if (shown.isEmpty())
    return;
  remember();
  emit picked(shown.first().toMap());
}

void Search::submit() {
  if (word().isEmpty())
    return;
  if (m_status == Ready && !m_wait.isActive() &&
      m_answered.compare(word(), Qt::CaseInsensitive) == 0) {
    pick();
    return;
  }
  m_submitted = true;
  // A word still waiting is asked now; one already asked is waited for.
  if (m_wait.isActive() || m_status == Failed)
    ask();
}

void Search::retry() {
  if (!word().isEmpty())
    ask();
}

void Search::open() {
  setQuery({});
  setKind({});
  if (!m_core)
    return;
  m_core->get("/api/v1/searches", {}, this, [this](const Core::Reply &reply) {
    // No history is an empty field, not worth a word.
    if (!reply.ok())
      return;
    QStringList recent;
    for (const QJsonValue &query : reply.json()["searches"].toArray())
      recent.append(query.toString());
    if (recent == m_recent)
      return;
    m_recent = recent;
    emit recentChanged();
  });
  if (m_popularAsked)
    return;
  m_popularAsked = true;
  m_core->get("/api/v1/catalogs", {}, this, [this](const Core::Reply &reply) {
    // Asked again on the next open: the core may have been starting.
    if (!reply.ok()) {
      m_popularAsked = false;
      return;
    }
    for (const QJsonValue &row : reply.json()["catalogs"].toArray())
      if (row["kind"].toString() == "movie" && row["id"].toString() == "top") {
        m_popular = new Shelf(m_core, row.toObject(), {}, {}, this);
        emit popularChanged();
        return;
      }
  });
}

void Search::remember() {
  const QString query = word();
  if (query.isEmpty() || !m_core)
    return;
  m_recent.removeIf([&](const QString &q) { return q.compare(query, Qt::CaseInsensitive) == 0; });
  m_recent.prepend(query);
  emit recentChanged();
  m_core->send("POST", "/api/v1/searches", {}, QJsonObject{{"query", query}}, this,
               [](const Core::Reply &) {});
}

void Search::forget(const QString &query) {
  if (!m_core)
    return;
  if (query.isEmpty())
    m_recent.clear();
  else
    m_recent.removeAll(query);
  emit recentChanged();
  m_core->send("DELETE", "/api/v1/searches", query.isEmpty() ? QUrlQuery() : QUrlQuery{{"q", query}},
               QJsonValue::Undefined, this, [](const Core::Reply &) {});
}

QJsonArray Search::rank(const QString &query, const QJsonArray &films, const QJsonArray &series) {
  const QString wanted = plain(query);
  const auto tier = [&](const QJsonValue &item) {
    const QString title = plain(item["title"].toString());
    if (title == wanted)
      return 0;
    if (title.startsWith(wanted))
      return 1;
    if (title.contains(" " + wanted))
      return 2;
    // Kept: the provider matched it on something not on screen, such as an
    // original title.
    return 3;
  };
  struct Ranked {
    int tier;
    qsizetype place;
    int kind;
    QJsonValue item;
  };
  QList<Ranked> ranked;
  for (qsizetype i = 0; i < films.size(); ++i)
    ranked.append({tier(films[i]), i, 0, films[i]});
  for (qsizetype i = 0; i < series.size(); ++i)
    ranked.append({tier(series[i]), i, 1, series[i]});
  std::sort(ranked.begin(), ranked.end(), [](const Ranked &a, const Ranked &b) {
    return std::tie(a.tier, a.place, a.kind) < std::tie(b.tier, b.place, b.kind);
  });
  QJsonArray out;
  for (const Ranked &r : ranked)
    out.append(r.item);
  return out;
}
