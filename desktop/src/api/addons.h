#pragma once

#include "core.h"

#include <QJsonArray>
#include <QObject>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <functional>

class QQmlEngine;
class QJSEngine;

// The installed addons as the core last confirmed them. Every change goes to
// the core and the list is what comes back: a row on screen is never ahead
// of the database, so a refused change is a list that did not move, with
// the reason beside it.
class Addons : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QVariantList current READ current NOTIFY changed)
  Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
  // The last load or change failure, cleared by the next answer.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  // Why the last address typed was refused, cleared by the next attempt.
  Q_PROPERTY(QString addError READ addError NOTIFY changed)
  // An address is being checked right now.
  Q_PROPERTY(bool adding READ adding NOTIFY changed)

public:
  explicit Addons(Core *core, QObject *parent = nullptr);
  static Addons *create(QQmlEngine *qml, QJSEngine *);

  QVariantList current() const { return m_current.toVariantList(); }
  bool loaded() const { return m_loaded; }
  QString error() const { return m_error; }
  QString addError() const { return m_addError; }
  bool adding() const { return m_adding; }

  Q_INVOKABLE void load();
  // Installs the addon at an address, or re-points the one installed from
  // it. The core fetches the manifest first, so an address nothing answers
  // at is refused.
  Q_INVOKABLE void add(const QString &url);
  Q_INVOKABLE void setEnabled(const QString &id, bool enabled);
  // The order is what the core breaks ties with, and the first catalogue is
  // the home screen.
  Q_INVOKABLE void move(const QString &id, int to);
  Q_INVOKABLE void remove(const QString &id);

signals:
  void changed();

private:
  // Applies [change] to the list when the core said yes, and keeps the error
  // when it did not.
  Core::Answer apply(std::function<void(const QJsonValue &)> change);
  void replace(const QJsonObject &addon);

  Core *m_core;
  QJsonArray m_current;
  bool m_loaded = false;
  QString m_error;
  QString m_addError;
  bool m_adding = false;
};
