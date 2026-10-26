#include "downloadlist.h"

#include "core.h"
#include "downloads.h"
#include "rows.h"
#include "settings.h"

#include <QQmlEngine>

// What a row knows, each with its value when it says nothing; the panel
// words it.
static const QVariantMap defaults = {
    {"type", ""}, {"key", ""}, {"section", ""}, {"kind", -1}, {"count", 0},
    {"ids", QStringList()}, {"itemId", ""}, {"title", ""}, {"poster", ""},
    {"runs", QVariantList()}, {"tag", ""}, {"size", 0.0}, {"fraction", 0.0}, {"rate", 0.0},
    {"eta", 0.0}, {"waitingSince", ""}, {"peers", 0}, {"resolved", false}, {"offline", false},
    {"error", ""}, {"opens", false}, {"expanded", false}, {"play", QVariantMap()},
    {"season", 0}, {"episode", 0}};

static QVariantMap blank(const QString &type, const QString &key) {
  QVariantMap row = defaults;
  row["type"] = type;
  row["key"] = key;
  return row;
}

static const QStringList sections = {"ready", "arriving", "waiting"};

static int sectionOf(int kind) {
  return kind == DownloadList::Ready ? 0 : kind == DownloadList::Arriving ? 1 : 2;
}

DownloadList::DownloadList(QObject *parent) : QObject(parent), m_rows(new Rows(defaults.keys(), this, "key")) {}

void DownloadList::componentComplete() {
  QQmlEngine *qml = qmlEngine(this);
  m_core = qml->singletonInstance<Core *>("Lumeo", "Core");
  m_downloads = qml->singletonInstance<Downloads *>("Lumeo", "Downloads");
  m_settings = qml->singletonInstance<LocalSettings *>("Lumeo", "LocalSettings");
  connect(m_downloads, &Downloads::changed, this, &DownloadList::update);
  connect(m_settings, &LocalSettings::changed, this, &DownloadList::update);
  update();
}

int DownloadList::kindOf(const QJsonObject &download) {
  if (download["locator"]["scheme"] == "file")
    return -1;
  const QString state = download["state"].toString();
  if (state == "done")
    return Ready;
  if (state == "active")
    return download["waitingSince"].toString().isEmpty() ? Arriving : Stalled;
  if (state == "paused")
    return download["pausedByUser"].toBool() ? Paused : -1;
  if (state == "failed")
    return Failed;
  return -1;
}

double DownloadList::perTransfer(const QJsonArray &downloads, const char *key) {
  QHash<QString, double> byTransfer;
  for (const QJsonValue &d : downloads) {
    const QString transfer = d["transfer"].toString();
    double &most = byTransfer[transfer.isEmpty() ? d["id"].toString() : transfer];
    most = std::max(most, d["progress"][key].toDouble());
  }
  double sum = 0;
  for (double v : byTransfer)
    sum += v;
  return sum;
}

// Episode numbers as runs within each season: [{season, first, last}].
static QVariantList runsOf(const QJsonArray &sorted) {
  QVariantList runs;
  int season = -1, first = 0, last = 0;
  for (const QJsonValue &d : sorted) {
    const int s = d["season"].toInt(), e = d["episode"].toInt();
    if (s == season && e <= last + 1) {
      last = std::max(last, e);
      continue;
    }
    if (season >= 0)
      runs.append(QVariantMap{{"season", season}, {"first", first}, {"last", last}});
    season = s;
    first = last = e;
  }
  if (season >= 0)
    runs.append(QVariantMap{{"season", season}, {"first", first}, {"last", last}});
  return runs;
}

// What the downloads say together: how much is here and how fast the rest
// comes, and how long they have waited, since the first of them stopped.
static void fill(QVariantMap &row, const QJsonArray &downloads) {
  double size = 0, completed = 0, eta = 0;
  QString since, error;
  for (const QJsonValue &d : downloads) {
    size += d["progress"]["total"].toDouble();
    completed += d["progress"]["completed"].toDouble();
    // Side by side, so done when the slowest is.
    eta = std::max(eta, d["progress"]["eta"].toDouble());
    const QString s = d["waitingSince"].toString();
    if (!s.isEmpty() && (since.isEmpty() || s < since))
      since = s;
    if (error.isEmpty())
      error = d["error"].toString();
  }
  const QJsonValue first = downloads.first();
  row["size"] = size;
  row["fraction"] = size > 0 ? std::clamp(completed / size, 0.0, 1.0) : 0.0;
  row["rate"] = DownloadList::perTransfer(downloads, "rate");
  row["eta"] = eta;
  row["waitingSince"] = since;
  row["error"] = error;
  row["peers"] = first["progress"]["peers"].toInt();
  row["resolved"] = first["resolved"].toBool();
  row["offline"] = first["offline"].toBool();
  QStringList ids;
  for (const QJsonValue &d : downloads)
    ids.append(d["id"].toString());
  row["ids"] = ids;
}

// The download a click plays: a finished one, or one that streams while it
// arrives; none sends the click to the title's page.
static QVariantMap playOf(const QJsonValue &d) {
  if (d["state"] != "done" && !d["ready"].toBool())
    return {};
  return {{"id", d["id"]}, {"season", d["season"].toInt()}, {"episode", d["episode"].toInt()}};
}

QList<QVariantMap> DownloadList::arrange(const QJsonArray &listed, const QSet<QString> &opened,
                                         const QHash<QString, QJsonObject> &next) {
  // Rows keep the order the downloads came in.
  QStringList order;
  QHash<QString, QJsonArray> grouped;
  QHash<QString, int> kinds;
  for (const QJsonValue &d : listed) {
    const int kind = kindOf(d.toObject());
    if (kind < 0)
      continue;
    const QString itemId = d["itemId"].toString();
    // Every episode of a series, whatever its season: one title, one row.
    const QString key = d["episode"].toInt() > 0 && !itemId.isEmpty()
                            ? QString("%1:%2").arg(kind).arg(itemId)
                            : "one:" + d["id"].toString();
    if (!grouped.contains(key)) {
      order.append(key);
      kinds.insert(key, kind);
    }
    grouped[key].append(d);
  }
  for (QJsonArray &downloads : grouped) {
    QList<QJsonValue> sorted(downloads.begin(), downloads.end());
    std::sort(sorted.begin(), sorted.end(), [](const QJsonValue &a, const QJsonValue &b) {
      return std::pair(a["season"].toInt(), a["episode"].toInt()) <
             std::pair(b["season"].toInt(), b["episode"].toInt());
    });
    downloads = QJsonArray();
    for (const QJsonValue &d : sorted)
      downloads.append(d);
  }

  QList<QVariantMap> rows;
  for (int section = 0; section < sections.size(); ++section) {
    QVariantMap header = blank("section", "section:" + sections[section]);
    header["section"] = sections[section];
    int count = 0;
    double eta = 0;
    QList<QVariantMap> below;
    for (const QString &key : order) {
      const int kind = kinds[key];
      if (sectionOf(kind) != section)
        continue;
      const QJsonArray downloads = grouped[key];
      const QJsonValue first = downloads.first();
      const QString itemId = first["itemId"].toString();
      // Downloads rather than rows: "3 ready" is episodes one can watch.
      count += downloads.size();
      QVariantMap row = blank("row", key);
      row["section"] = sections[section];
      row["kind"] = kind;
      row["itemId"] = itemId;
      row["title"] = first["name"].toString();
      fill(row, downloads);
      eta = std::max(eta, row["eta"].toDouble());
      if (first["episode"].toInt() > 0) {
        row["runs"] = runsOf(downloads);
      } else {
        // Which copy it is, the one thing that tells two copies apart.
        const QJsonObject release = first["release"].toObject();
        QStringList tag;
        for (const QString &part : {release["resolution"].toString(), release["hdr"][0].toString()})
          if (!part.isEmpty())
            tag.append(part);
        row["tag"] = tag.join(' ');
      }
      row["opens"] = downloads.size() > 1;
      row["expanded"] = downloads.size() > 1 && opened.contains(key);
      // A season on disk plays the episode the core says is next, when it is
      // among them, else the first of them.
      QJsonValue played = first;
      if (kind == Ready && next.contains(itemId))
        for (const QJsonValue &d : downloads)
          if (d["season"] == next[itemId]["season"] && d["episode"] == next[itemId]["episode"])
            played = d;
      row["play"] = playOf(played);
      row["season"] = played["season"].toInt();
      row["episode"] = played["episode"].toInt();
      below.append(row);
      if (!row["expanded"].toBool())
        continue;
      for (const QJsonValue &d : downloads) {
        QVariantMap episode = blank("episode", d["id"].toString());
        episode["section"] = sections[section];
        episode["kind"] = kind;
        episode["itemId"] = itemId;
        episode["title"] = row["title"];
        fill(episode, QJsonArray{d});
        episode["play"] = playOf(d);
        episode["season"] = d["season"].toInt();
        episode["episode"] = d["episode"].toInt();
        below.append(episode);
      }
    }
    if (below.isEmpty())
      continue;
    header["count"] = count;
    header["eta"] = section == 1 ? eta : 0.0;
    rows.append(header);
    rows.append(below);
  }
  return rows;
}

void DownloadList::update() {
  QJsonArray listed, active;
  bool allDone = true;
  double completed = 0, total = 0;
  int peers = 0;
  for (const QJsonValue &d : m_downloads->list()) {
    const int kind = kindOf(d.toObject());
    if (kind < 0)
      continue;
    if (kind == Ready &&
        !m_settings->showsFinished(QDateTime::fromString(d["updatedAt"].toString(), Qt::ISODate)))
      continue;
    listed.append(d);
    allDone = allDone && kind == Ready;
    if (kind == Arriving || kind == Stalled) {
      active.append(d);
      completed += d["progress"]["completed"].toDouble();
      total += d["progress"]["total"].toDouble();
      peers += d["progress"]["peers"].toInt();
    }
  }
  m_running = int(active.size());
  m_fraction = total > 0 ? completed / total : 0;
  m_rate = perTransfer(active, "rate");
  m_upload = perTransfer(listed, "upload");
  m_ring = m_running > 0 ? (peers == 0 ? "stalled" : "arriving")
           : !listed.isEmpty() && allDone ? "done"
                                          : "rest";

  QList<QVariantMap> rows = arrange(listed, m_opened, m_next);
  // The catalogue's name and poster once they are known; the release's name
  // until then.
  for (QVariantMap &row : rows) {
    const QVariantMap item = m_downloads->itemOf(row["itemId"].toString());
    if (!item.value("title").toString().isEmpty())
      row["title"] = item["title"];
    row["poster"] = item.value("poster").toString();
  }
  m_rows->set(rows);
  emit changed();
}

void DownloadList::toggle(const QString &key) {
  if (!m_opened.remove(key))
    m_opened.insert(key);
  update();
}

void DownloadList::refresh() {
  QSet<QString> series;
  for (const QJsonValue &d : m_downloads->list())
    if (d["state"] == "done" && d["episode"].toInt() > 0 && !d["itemId"].toString().isEmpty())
      series.insert(d["itemId"].toString());
  for (const QString &itemId : series)
    m_core->get("/api/v1/progress/" + Core::segment(itemId), {}, this,
                [this, itemId](const Core::Reply &reply) {
                  // Without it Play opens the first episode of the row.
                  if (!reply.ok())
                    return;
                  m_next.insert(itemId, reply.json()["next"].toObject());
                  update();
                });
  update();
}

void DownloadList::clear() { m_settings->clearFinished(); }
