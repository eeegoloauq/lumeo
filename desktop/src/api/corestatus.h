#pragma once

#include <QObject>
#include <QQmlParserStatus>
#include <QtQml/qqmlregistration.h>

class Core;

// Whether the core answers, and what it says about itself: where it listens,
// its source providers, its log and its download folder.
class CoreStatus : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  // Asked and not answered yet.
  Q_PROPERTY(bool asking READ asking NOTIFY changed)
  Q_PROPERTY(bool answering READ answering NOTIFY changed)
  // Why it did not answer.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  // How many source providers it runs; -1 until it said.
  Q_PROPERTY(int providers READ providers NOTIFY changed)
  // Where it listens by its own word, else the address this client uses.
  Q_PROPERTY(QString address READ address NOTIFY changed)
  Q_PROPERTY(QString logPath READ logPath NOTIFY changed)
  Q_PROPERTY(QString downloadDir READ downloadDir NOTIFY changed)

public:
  explicit CoreStatus(QObject *parent = nullptr) : QObject(parent) {}

  void classBegin() override {}
  void componentComplete() override;

  bool asking() const { return m_asking; }
  bool answering() const { return m_answering; }
  QString error() const { return m_error; }
  int providers() const { return m_providers; }
  QString address() const;
  QString logPath() const { return m_logPath; }
  QString downloadDir() const { return m_downloadDir; }

  Q_INVOKABLE void load();

signals:
  void changed();

private:
  Core *m_core = nullptr;
  bool m_asking = false;
  bool m_answering = false;
  QString m_error;
  int m_providers = -1;
  QString m_addr;
  QString m_logPath;
  QString m_downloadDir;
};
