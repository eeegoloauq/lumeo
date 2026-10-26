#pragma once

#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// Facts that belong only to this machine, kept in client.json beside the
// Flutter client's: the same file and keys, so an update keeps them. Keys
// this client does not read yet are written back as they were. A choice
// that should follow somebody to another client belongs in the core.
class LocalSettings : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY changed)
  // Frames over the seek bar, from a second mpv on the same file.
  Q_PROPERTY(bool timelinePreviews READ timelinePreviews WRITE setTimelinePreviews NOTIFY changed)
  // Where screenshots go; empty for Pictures/Lumeo.
  Q_PROPERTY(QString screenshotsDir READ screenshotsDir NOTIFY changed)

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

signals:
  void changed();

private:
  void set(const QString &key, const QJsonValue &value);
  void write();

  QString m_path;
  QJsonObject m_values;
  // A slider's drag is one write, half a second after it stops.
  QTimer m_save;
};
