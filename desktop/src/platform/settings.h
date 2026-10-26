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

public:
  explicit LocalSettings(const QString &path, QObject *parent = nullptr);
  ~LocalSettings() override;
  static LocalSettings *create(QQmlEngine *, QJSEngine *);

  // The settings folder: XDG's on Linux, %APPDATA%\Lumeo on Windows.
  static QString configDir();

  // Restored up to 100: a film mixed loud is turned up again on purpose.
  double volume() const;
  void setVolume(double volume);

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
