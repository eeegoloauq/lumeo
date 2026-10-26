#pragma once

#include <QObject>
#include <QQmlParserStatus>
#include <QUrlQuery>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class Core;
class Downloads;

// What is on the core's disk: its share of the filesystem, every title it
// keeps, and the artwork it caches. Freeing
// goes one at a time, and the list is read again once the core has freed.
class Storage : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(bool known READ known NOTIFY changed)
  // The last failure to read or to free, cleared by the next success.
  Q_PROPERTY(QString error READ error NOTIFY changed)
  Q_PROPERTY(double used READ used NOTIFY changed)
  // The filesystem under the downloads; zero when the core could not read it.
  Q_PROPERTY(double diskTotal READ diskTotal NOTIFY changed)
  Q_PROPERTY(double diskFree READ diskFree NOTIFY changed)
  Q_PROPERTY(double cache READ cache NOTIFY changed)
  // {itemId, title, poster, kind, onDisk, downloads: [{id, state, ...}]}
  Q_PROPERTY(QVariantList titles READ titles NOTIFY changed)
  // What is being freed: a title's key, "all" or "cache"; empty when nothing.
  Q_PROPERTY(QString freeing READ freeing NOTIFY changed)

public:
  explicit Storage(QObject *parent = nullptr) : QObject(parent) {}

  void classBegin() override {}
  void componentComplete() override;

  bool known() const { return m_known; }
  QString error() const { return m_error; }
  double used() const { return m_used; }
  double diskTotal() const { return m_diskTotal; }
  double diskFree() const { return m_diskFree; }
  double cache() const { return m_cache; }
  QVariantList titles() const { return m_titles; }
  QString freeing() const { return m_freeing; }

  Q_INVOKABLE void load();
  // A title by its key: the item's id, or for a download the catalogue no
  // longer knows, its downloads one by one.
  Q_INVOKABLE void free(const QString &key);
  Q_INVOKABLE void freeAll();
  // No confirmation: the artwork downloads again as it is shown.
  Q_INVOKABLE void clearCache();

  static QString keyOf(const QVariantMap &title);

signals:
  void changed();

private:
  void act(const QString &what, const QList<std::pair<QString, QUrlQuery>> &deletes);

  Core *m_core = nullptr;
  Downloads *m_downloads = nullptr;
  bool m_known = false;
  QString m_error;
  double m_used = 0, m_diskTotal = 0, m_diskFree = 0, m_cache = 0;
  QVariantList m_titles;
  QString m_freeing;
};
