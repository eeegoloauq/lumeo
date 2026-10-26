#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>

// The rows of a menu, changed in place: a list handed to QML as a value is
// drawn again whole on every change, and a row made again under the pointer
// loses the click whose press and release straddle it. Every row has every
// role.
class Rows : public QAbstractListModel {
  Q_OBJECT
  QML_ELEMENT
  QML_UNCREATABLE("made by what fills it")

public:
  // With a [key] role, rows are told apart by it rather than by place: a
  // row keeps its delegate when rows before it come or go, which a delegate
  // chosen by the row's type needs.
  Rows(const QStringList &roles, QObject *parent = nullptr, const QString &key = {});

  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  // The rows as they are now: the ones that differ are changed, the rest
  // stay, and the count is made up at the end.
  void set(const QList<QVariantMap> &rows);
  const QList<QVariantMap> &rows() const { return m_rows; }

private:
  void setByKey(const QList<QVariantMap> &rows);

  QList<QByteArray> m_roles;
  QString m_key;
  QList<QVariantMap> m_rows;
};
