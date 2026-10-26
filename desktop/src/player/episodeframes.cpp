#include "episodeframes.h"

#include "core.h"
#include "downloads.h"
#include "folders.h"
#include "framegrabber.h"

#include <QDir>
#include <QFile>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QUrl>

EpisodeFrames::EpisodeFrames(Core *core, Downloads *downloads, const QString &directory,
                             QObject *parent)
    : QObject(parent), m_core(core), m_downloads(downloads), m_directory(directory) {
  // A dot is a frame mpv was still writing when the client quit.
  for (const QString &file : QDir(directory).entryList(QDir::Files))
    if (!file.startsWith('.'))
      m_known.insert(file);
  connect(downloads, &Downloads::changed, this, &EpisodeFrames::update);
  update();
}

EpisodeFrames *EpisodeFrames::create(QQmlEngine *qml, QJSEngine *) {
  return new EpisodeFrames(qml->singletonInstance<Core *>("Lumeo", "Core"),
                           qml->singletonInstance<Downloads *>("Lumeo", "Downloads"),
                           Folders::cache() + "/stills");
}

QString EpisodeFrames::name(const QString &itemId, int season, int episode) {
  return QString("%1-s%2e%3.jpg")
      .arg(QString::fromUtf8(QUrl::toPercentEncoding(itemId)))
      .arg(season)
      .arg(episode);
}

QVariantMap EpisodeFrames::known() const {
  static const QRegularExpression named("^(.*)-s(\\d+)e(\\d+)\\.jpg$");
  QVariantMap known;
  for (const QString &file : m_known) {
    const QRegularExpressionMatch match = named.match(file);
    if (match.hasMatch())
      known.insert(QString("%1/%2/%3")
                       .arg(QUrl::fromPercentEncoding(match.captured(1).toUtf8()),
                            match.captured(2), match.captured(3)),
                   QUrl::fromLocalFile(m_directory + "/" + file).toString());
  }
  return known;
}

void EpisodeFrames::update() {
  if (m_grabber)
    return;
  for (const QVariant &d : m_downloads->all()) {
    const QVariantMap download = d.toMap();
    if (download.value("state") != "done" || download.value("episode").toInt() == 0)
      continue;
    const QString file = name(download.value("itemId").toString(),
                              download.value("season").toInt(), download.value("episode").toInt());
    if (m_known.contains(file) || m_tried.contains(file))
      continue;
    m_tried.insert(file);
    QDir().mkpath(m_directory);
    const QString part = m_directory + "/." + file;
    const QString stream = m_core->url("/api/v1/downloads/" +
                                       Core::segment(download.value("id").toString()) + "/stream")
                               .toString();
    m_grabber = new FrameGrabber(stream, m_core->headers(), this);
    // A save that fails reports itself, and the grabber says it failed too.
    auto done = [this, part, file](bool saved) {
      if (!m_grabber)
        return;
      if (saved && QFile::rename(part, m_directory + "/" + file)) {
        m_known.insert(file);
        emit changed();
      }
      m_grabber->deleteLater();
      m_grabber = nullptr;
      update();
    };
    connect(m_grabber, &FrameGrabber::failed, this, [done] { done(false); });
    connect(m_grabber, &FrameGrabber::opened, this, [this, part, done] {
      m_grabber->save(33, "absolute-percent+keyframes", part, done);
    });
    if (m_grabber->isDead())
      done(false);
    return;
  }
}
