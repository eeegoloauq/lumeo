#pragma once

#include <QObject>
#include <QQmlParserStatus>
#include <QString>
#include <QtQml/qqmlregistration.h>

class Core;
class Preferences;

// The viewer's own data as a file, to take to another core: what the core
// writes is saved as it is, and a file picked is sent as it is, the core
// checking it whole (docs/core.md).
class PersonalData : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  // An export or an import is under way; a second waits for it.
  Q_PROPERTY(bool busy READ busy NOTIFY changed)
  // The last failure, cleared by the next start.
  Q_PROPERTY(QString error READ error NOTIFY changed)

public:
  explicit PersonalData(QObject *parent = nullptr) : QObject(parent) {}
  PersonalData(Core *core, Preferences *preferences, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  bool busy() const { return m_busy; }
  QString error() const { return m_error; }

  Q_INVOKABLE void exportTo(const QString &path);
  Q_INVOKABLE void importFrom(const QString &path);

  // A file larger than this is not read: far above what the core takes, it
  // keeps a film picked by mistake out of memory.
  static constexpr qint64 largest = 64 << 20;

signals:
  void changed();
  void exported();
  // [written] is how many entries the core added or replaced.
  void imported(int written);

private:
  bool begin();
  void fail(const QString &why);

  Core *m_core = nullptr;
  Preferences *m_preferences = nullptr;
  bool m_busy = false;
  QString m_error;
};
