#include "rows.h"

Rows::Rows(const QStringList &roles, QObject *parent, const QString &key)
    : QAbstractListModel(parent), m_key(key) {
  for (const QString &role : roles)
    m_roles.append(role.toUtf8());
}

int Rows::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant Rows::data(const QModelIndex &index, int role) const {
  const int at = role - Qt::UserRole;
  if (!index.isValid() || index.row() >= m_rows.size() || at < 0 || at >= m_roles.size())
    return {};
  return m_rows[index.row()].value(QString::fromUtf8(m_roles[at]));
}

QHash<int, QByteArray> Rows::roleNames() const {
  QHash<int, QByteArray> names;
  for (int i = 0; i < m_roles.size(); ++i)
    names.insert(Qt::UserRole + i, m_roles[i]);
  return names;
}

void Rows::set(const QList<QVariantMap> &rows) {
  if (!m_key.isEmpty()) {
    setByKey(rows);
    return;
  }
  const qsizetype kept = std::min(rows.size(), m_rows.size());
  for (qsizetype i = 0; i < kept; ++i) {
    if (m_rows[i] == rows[i])
      continue;
    m_rows[i] = rows[i];
    emit dataChanged(index(int(i)), index(int(i)));
  }
  if (rows.size() > m_rows.size()) {
    beginInsertRows({}, int(m_rows.size()), int(rows.size() - 1));
    m_rows.append(rows.mid(m_rows.size()));
    endInsertRows();
  } else if (rows.size() < m_rows.size()) {
    beginRemoveRows({}, int(rows.size()), int(m_rows.size() - 1));
    m_rows.resize(rows.size());
    endRemoveRows();
  }
}

// Each new row in turn: the old one with its key moved up to its place and
// changed, or a new one put there; what is left over at the end went.
void Rows::setByKey(const QList<QVariantMap> &rows) {
  for (int i = 0; i < rows.size(); ++i) {
    const QVariant key = rows[i].value(m_key);
    int at = -1;
    for (int j = i; j < m_rows.size() && at < 0; ++j)
      if (m_rows[j].value(m_key) == key)
        at = j;
    if (at < 0) {
      beginInsertRows({}, i, i);
      m_rows.insert(i, rows[i]);
      endInsertRows();
      continue;
    }
    if (at > i) {
      beginMoveRows({}, at, at, {}, i);
      m_rows.move(at, i);
      endMoveRows();
    }
    if (m_rows[i] != rows[i]) {
      m_rows[i] = rows[i];
      emit dataChanged(index(i), index(i));
    }
  }
  if (m_rows.size() > rows.size()) {
    beginRemoveRows({}, int(rows.size()), int(m_rows.size() - 1));
    m_rows.resize(rows.size());
    endRemoveRows();
  }
}
