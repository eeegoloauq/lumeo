#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QLocale>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// Facts that belong only to this machine, kept in client.json: the file and
// keys the earlier Flutter client wrote, so an update keeps them. Keys this
// client does not read are written back as they were. A choice
// that should follow somebody to another client belongs in the core.
class LocalSettings : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY changed)
  // Frames over the seek bar, from a second mpv on the same file.
  Q_PROPERTY(bool timelinePreviews READ timelinePreviews WRITE setTimelinePreviews NOTIFY changed)
  // Where screenshots go; empty for Pictures/Lumeo.
  Q_PROPERTY(QString screenshotsDir READ screenshotsDir WRITE setScreenshotsDir NOTIFY changed)
  // The interface's language as a code from `languages`; empty follows the
  // system.
  Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
  Q_PROPERTY(QVariantList languages READ languages CONSTANT)
  // Leaving the player the first time says that Lumeo keeps what was
  // watched, once per machine (decisions/interface.md, Help).
  Q_PROPERTY(bool keepsTold READ keepsTold WRITE setKeepsTold NOTIFY changed)
  // The order of My list: "added", "title", "year" or "rating". A way of
  // looking at the list on this screen, so not the core's
  // (decisions/library.md).
  Q_PROPERTY(QString listSort READ listSort WRITE setListSort NOTIFY changed)
  // Closing the window leaves the app running, and the app starts at login
  // without one. Login needs the background, so either carries the other
  // (decisions/interface.md).
  Q_PROPERTY(bool background READ background WRITE setBackground NOTIFY changed)
  Q_PROPERTY(bool autostart READ autostart WRITE setAutostart NOTIFY changed)

public:
  explicit LocalSettings(const QString &path, QObject *parent = nullptr);
  ~LocalSettings() override;
  static LocalSettings *create(QQmlEngine *, QJSEngine *);

  // Restored up to 100: a film mixed loud is turned up again on purpose.
  double volume() const;
  void setVolume(double volume);
  bool timelinePreviews() const { return m_values.value("timelinePreviews").toBool(true); }
  void setTimelinePreviews(bool on) { set("timelinePreviews", on); }
  QString screenshotsDir() const { return m_values.value("screenshotsDir").toString(); }
  void setScreenshotsDir(const QString &dir) { set("screenshotsDir", dir); }
  QString language() const;
  void setLanguage(const QString &code);
  QVariantList languages() const { return m_languages; }
  QString listSort() const;
  void setListSort(const QString &order);
  bool keepsTold() const { return m_values.value("keepsTold").toBool(); }
  void setKeepsTold(bool told) { set("keepsTold", told); }
  // The version whose notes were last shown: null on a first run, which has
  // nothing to compare with; empty from a copy that kept none.
  QString lastSeenVersion() const;
  void setLastSeenVersion(const QString &version) { set("lastSeenVersion", version); }
  // The newer release whose notice was closed, and when.
  QString dismissedUpdate() const { return m_values.value("dismissedUpdate").toString(); }
  QDateTime updateDismissedAt() const;
  void dismissUpdate(const QString &version);
  bool background() const { return m_values.value("background").toBool(); }
  void setBackground(bool on);
  bool autostart() const { return background() && m_values.value("autostart").toBool(); }
  void setAutostart(bool on);
  // A finished download stays in the downloads panel for a day, or until
  // its Clear: a fact of this screen, not of the core's disk.
  Q_INVOKABLE void clearFinished();
  bool showsFinished(const QDateTime &finishedAt) const;
  // This machine's choices back to their defaults; the volume is not one.
  Q_INVOKABLE void resetChoices();
  // The language to show: the chosen one, else the system's.
  QLocale locale() const;

signals:
  void changed();
  void languageChanged();

private:
  void set(const QString &key, const QJsonValue &value);
  void write();

  QString m_path;
  bool m_existed = false;
  QJsonObject m_values;
  QVariantList m_languages;
  // A slider's drag is one write, half a second after it stops.
  QTimer m_save;
};
