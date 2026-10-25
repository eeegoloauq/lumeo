#pragma once

#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <deque>
#include <functional>

class Core;
class QQmlEngine;
class QJSEngine;

// The last preferences document the core confirmed, and the failure to get
// a newer one when there is one.
class Preferences : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // Empty until the core has answered.
  Q_PROPERTY(QVariantMap current READ current NOTIFY changed)
  // The languages a preference may name, with what files call them.
  Q_PROPERTY(QVariantList languages READ languages NOTIFY changed)
  // The last failure, cleared by the next answer.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  // The preferences the failed write carried; none for a read or a reset.
  Q_PROPERTY(QStringList failedKeys READ failedKeys NOTIFY changed)

public:
  explicit Preferences(Core *core, QObject *parent = nullptr);
  static Preferences *create(QQmlEngine *qml, QJSEngine *);

  QVariantMap current() const { return m_current.toVariantMap(); }
  QVariantList languages() const { return m_languages; }
  QString error() const { return m_error; }
  QStringList failedKeys() const { return m_failedKeys; }

  // Asks for the whole document and the language table beside it. The table
  // failing costs names in the menus, not the preferences.
  Q_INVOKABLE void load();
  // Sends a partial document and keeps the whole one that comes back.
  Q_INVOKABLE void patch(const QVariantMap &patch);
  // Every preference back to the core's default. A burst still waiting to be
  // remembered is dropped: it was chosen before the reset.
  Q_INVOKABLE void reset();
  // Only the last value of each key chosen during a burst (a key held down,
  // a stepper clicked five times) goes out, as one patch.
  Q_INVOKABLE void remember(const QString &key, const QVariant &value);

  // How long a burst lasts; tests shorten it.
  int rememberDelay = 500;

signals:
  void changed();

private:
  using Write = std::function<void()>;
  void write(const QByteArray &method, const QJsonObject &body, const QStringList &keys);
  void next();

  Core *m_core;
  QJsonObject m_current;
  QVariantList m_languages;
  QString m_error;
  QStringList m_failedKeys;
  QVariantMap m_remembered;
  QTimer m_rememberTimer;
  // Writes go one after another, so the core applies them in the order they
  // were made: a patch on its way when Reset is pressed cannot land after
  // the reset and bring its value back.
  std::deque<Write> m_writes;
  bool m_writing = false;
};
