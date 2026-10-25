#include "core.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QUrlQuery>

namespace {

const QUrl defaultCore("http://127.0.0.1:7666");

// Where the core keeps its token: the directory it picks, LUMEO_DATA first.
QString dataDir() {
  const QString chosen = qEnvironmentVariable("LUMEO_DATA");
  if (!chosen.isEmpty())
    return chosen;
#ifdef Q_OS_WIN
  return qEnvironmentVariable("LOCALAPPDATA") + "/Lumeo/Data";
#else
  const QString xdg = qEnvironmentVariable("XDG_DATA_HOME");
  return (xdg.isEmpty() ? QDir::homePath() + "/.local/share" : xdg) + "/lumeo";
#endif
}

QString gib(double bytes) { return QString::number(bytes / (1 << 30), 'f', 1) + " GB"; }

} // namespace

Core::Core(QObject *parent) : QObject(parent) {
  const QString address = qEnvironmentVariable("LUMEO_CORE");
  m_base = address.isEmpty() ? defaultCore : QUrl(address);
  // The local core's secret goes to the local core only.
  if (m_base == defaultCore) {
    QFile file(dataDir() + "/api-token");
    if (file.open(QIODevice::ReadOnly))
      m_token = file.readAll().trimmed();
  }
  m_poll.setInterval(1000);
  m_poll.setSingleShot(true);
  connect(&m_poll, &QTimer::timeout, this, [this] { waitForReady(m_waitingFor); });
}

QStringList Core::headers() const {
  return m_token.isEmpty() ? QStringList{} : QStringList{"Authorization: Bearer " + m_token};
}

void Core::search(const QString &query) {
  for (const QString kind : {"movie", "series"})
    request("GET", "/api/v1/search", QUrlQuery{{"q", query}, {"kind", kind}}, nullptr,
            [this, query, kind](const QJsonValue &json) {
              QVariantList items;
              for (const QJsonValue &item : json["items"].toArray())
                items.append(item.toObject().toVariantMap());
              emit searched(query, kind, items);
            });
}

void Core::sources(const QString &itemId, int season, int episode) {
  QUrlQuery query{{"item", itemId}};
  if (season > 0)
    query.addQueryItem("season", QString::number(season));
  if (episode > 0)
    query.addQueryItem("episode", QString::number(episode));
  setStatus("Asking for copies…");
  request("GET", "/api/v1/sources", query, nullptr, [this](const QJsonValue &json) {
    m_sources = json["sources"].toArray();
    QVariantList rows;
    for (const QJsonValue &source : m_sources) {
      const QJsonObject release = source["release"].toObject();
      rows.append(QVariantMap{
          {"name", source["rawName"].toString()},
          {"resolution", release["resolution"].toString()},
          {"size", gib(source["size"].toDouble())},
          {"seeders", source["seeders"].toInt()},
      });
    }
    setStatus(rows.isEmpty() ? "No copies" : QString());
    emit sourcesListed(rows);
  });
}

void Core::play(const QString &itemId, int index, int season, int episode) {
  if (index < 0 || index >= m_sources.size())
    return;
  const QJsonObject body{
      {"itemId", itemId},
      {"season", season},
      {"episode", episode},
      {"source", m_sources[index]},
  };
  setStatus("Starting the download…");
  request("POST", "/api/v1/downloads", {}, &body,
          [this](const QJsonValue &json) { waitForReady(json["id"].toString()); });
}

void Core::openLocal(const QString &path) {
  const QJsonObject body{{"path", path}};
  request("POST", "/api/v1/local", {}, &body,
          [this](const QJsonValue &json) { waitForReady(json["id"].toString()); });
}

// The core says `ready` once the front of the file is on disk; before that
// mpv would block on its first read (docs/decisions/player.md).
void Core::waitForReady(const QString &downloadId) {
  m_poll.stop();
  m_waitingFor = downloadId;
  request("GET", "/api/v1/downloads/" + QUrl::toPercentEncoding(downloadId), {}, nullptr,
          [this, downloadId](const QJsonValue &json) {
            if (downloadId != m_waitingFor)
              return;
            if (json["ready"].toBool()) {
              setStatus({});
              emit playable(m_base.resolved(QUrl("/api/v1/downloads/" +
                                                 QUrl::toPercentEncoding(downloadId) + "/stream"))
                                .toString());
              return;
            }
            const QJsonObject progress = json["progress"].toObject();
            setStatus(QString("Waiting: %1 peers, %2 of %3")
                          .arg(progress["peers"].toInt())
                          .arg(gib(progress["completed"].toDouble()),
                               gib(progress["total"].toDouble())));
            m_poll.start();
          });
}

void Core::request(const QByteArray &method, const QString &path, const QUrlQuery &query,
                   const QJsonObject *body, const Answer &answer) {
  QUrl url = m_base.resolved(QUrl(path));
  url.setQuery(query);
  QNetworkRequest request(url);
  // A core that stopped answering is an error, not a spinner.
  request.setTransferTimeout(20000);
  if (!m_token.isEmpty())
    request.setRawHeader("Authorization", "Bearer " + m_token);
  QByteArray data;
  if (body) {
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    data = QJsonDocument(*body).toJson(QJsonDocument::Compact);
  }
  QNetworkReply *reply = m_network.sendCustomRequest(request, method, data);
  connect(reply, &QNetworkReply::finished, this, [this, reply, answer, method, path] {
    reply->deleteLater();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status < 200 || status >= 300) {
      setStatus(QString("%1 %2 → %3 %4")
                    .arg(QString(method), path)
                    .arg(status)
                    .arg(status ? QString(reply->readAll()).trimmed() : reply->errorString()));
      return;
    }
    answer(QJsonDocument::fromJson(reply->readAll()).object());
  });
}

void Core::setStatus(const QString &status) {
  if (status == m_status)
    return;
  m_status = status;
  emit statusChanged();
}
