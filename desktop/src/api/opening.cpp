#include "opening.h"

#include "core.h"
#include "downloads.h"

#include <QFileInfo>
#include <QJsonObject>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QUrl>

Opening::Opening(Core *core, Downloads *downloads, QObject *parent)
    : QObject(parent), m_core(core), m_downloads(downloads) {}

Opening *Opening::create(QQmlEngine *qml, QJSEngine *) {
  return new Opening(qml->singletonInstance<Core *>("Lumeo", "Core"),
                     qml->singletonInstance<Downloads *>("Lumeo", "Downloads"));
}

void Opening::open(const QString &target) {
  if (QUrl(target).scheme() == "lumeo")
    openLink(target);
  else
    openFile(target);
}

void Opening::openFile(const QString &path) {
  const QString name = QFileInfo(path).fileName();
  m_downloads->openLocal(path, this, [this, name](const Core::Reply &reply) {
    if (!reply.ok()) {
      emit failed(name, reply.message());
      return;
    }
    const QJsonObject download = reply.json().toObject();
    const QString id = download["id"].toString();
    const QString itemId = download["itemId"].toString();
    if (itemId.isEmpty()) {
      emit play(id, name);
      return;
    }
    m_core->get("/api/v1/items/" + Core::segment(itemId), {}, this,
                [this, id, name](const Core::Reply &reply) {
                  // Not a catalogue title: the file plays under its own name.
                  const QString title = reply.ok() ? reply.json()["title"].toString() : QString();
                  emit play(id, title.isEmpty() ? name : title);
                });
  });
}

// lumeo://title/<kind>/<imdb>, the link the share page hands over (site/).
void Opening::openLink(const QString &link) {
  const QUrl url(link);
  // A browser may hand the link over with a slash added at the end.
  const QStringList segments = url.path().split('/', Qt::SkipEmptyParts);
  static const QRegularExpression imdb("^tt[0-9]+$");
  if (url.host() != "title" || segments.size() != 2 ||
      (segments[0] != "movie" && segments[0] != "series") || !imdb.match(segments[1]).hasMatch()) {
    emit failed(link, {});
    return;
  }
  m_core->get("/api/v1/find", QUrlQuery{{"imdb", segments[1]}, {"kind", segments[0]}}, this,
              [this, id = segments[1]](const Core::Reply &reply) {
                if (reply.ok())
                  emit title(reply.json().toObject().toVariantMap());
                else
                  emit failed(id, reply.message());
              });
}
