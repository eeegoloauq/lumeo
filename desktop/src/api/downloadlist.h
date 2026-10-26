#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QQmlParserStatus>
#include <QSet>
#include <QtQml/qqmlregistration.h>

#include "rows.h"

class Core;
class Downloads;
class LocalSettings;

// The downloads panel and the ring that opens it. The panel is grouped by
// what can be done, not by title (decisions/interface.md): Ready to watch,
// Arriving, Waiting. A title's downloads in one state are one row, which
// opens into its episodes.
class DownloadList : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  // Sections, rows and opened episodes as one list, told apart by `type`:
  // "section", "row" or "episode".
  Q_PROPERTY(Rows *rows READ rows CONSTANT)
  // The ring: "rest", "arriving", "stalled" while nobody sends any of it,
  // or "done" when all that is listed is on disk.
  Q_PROPERTY(QString ring READ ring NOTIFY changed)
  // How much of everything arriving is here.
  Q_PROPERTY(double fraction READ fraction NOTIFY changed)
  Q_PROPERTY(int running READ running NOTIFY changed)
  Q_PROPERTY(double rate READ rate NOTIFY changed)
  Q_PROPERTY(double upload READ upload NOTIFY changed)

public:
  enum Kind { Ready, Arriving, Stalled, Paused, Failed };
  Q_ENUM(Kind)

  explicit DownloadList(QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  // -1 for what the panel does not list: a file of this machine's, and a
  // download paused because the core stopped rather than by anybody, which
  // the core picks up again itself.
  static int kindOf(const QJsonObject &download);
  // [listed] as the panel's list. A title's row opens into its episodes when
  // its key is in [opened]; a row of finished episodes plays the one
  // [next] names by title, {season, episode}, when it is among them.
  static QList<QVariantMap> arrange(const QJsonArray &listed, const QSet<QString> &opened,
                                    const QHash<QString, QJsonObject> &next);
  // The sum of [key] in the downloads' progress, counting each transfer
  // once: a pack's episodes share one, and each reports all of it.
  static double perTransfer(const QJsonArray &downloads, const char *key);

  Rows *rows() const { return m_rows; }
  QString ring() const { return m_ring; }
  double fraction() const { return m_fraction; }
  int running() const { return m_running; }
  double rate() const { return m_rate; }
  double upload() const { return m_upload; }

  Q_INVOKABLE void toggle(const QString &key);
  // Read again as the panel opens: the day a finished download stays runs
  // out between polls that change nothing, and what was watched since
  // decides which episode a row's Play opens.
  Q_INVOKABLE void refresh();
  // Finished downloads out of the panel; they stay on disk.
  Q_INVOKABLE void clear();

signals:
  void changed();

private:
  void update();

  Core *m_core = nullptr;
  Downloads *m_downloads = nullptr;
  LocalSettings *m_settings = nullptr;
  Rows *m_rows;
  QSet<QString> m_opened;
  // The core's next episode by title, asked once per opening.
  QHash<QString, QJsonObject> m_next;
  QString m_ring = "rest";
  double m_fraction = 0, m_rate = 0, m_upload = 0;
  int m_running = 0;
};
