#include "languages.h"

Languages::Languages(const QVariantList &list) {
  for (const QVariant &entry : list) {
    const QVariantMap language = entry.toMap();
    m_byCode.insert(language.value("code").toString().toLower(), language);
    for (const QVariant &alias : language.value("aliases").toList())
      m_byAlias.insert(alias.toString().toLower(), language);
  }
}

QString Languages::canonical(const QString &tag) const {
  const QString lower = tag.trimmed().toLower();
  if (lower.isEmpty())
    return {};
  if (const auto exact = m_byCode.constFind(lower); exact != m_byCode.constEnd())
    return exact->value("code").toString();
  if (const auto alias = m_byAlias.constFind(lower); alias != m_byAlias.constEnd())
    return alias->value("code").toString();
  // A regional variant: the base looked up on its own, and the region kept
  // where the core names that variant.
  const qsizetype dash = lower.indexOf('-');
  if (dash > 0) {
    const QString base = canonical(lower.left(dash));
    const QString regional = base + "-" + lower.mid(dash + 1).toUpper();
    const auto named = m_byCode.constFind(regional.toLower());
    return named != m_byCode.constEnd() ? named->value("code").toString() : base;
  }
  return lower;
}

QString Languages::name(const QString &tag) const {
  return m_byCode.value(canonical(tag).toLower()).value("name").toString();
}

int Languages::rank(const QString &tag, const QStringList &preferred) const {
  const QString code = canonical(tag);
  if (code.isEmpty())
    return -1;
  const qsizetype exact = preferred.indexOf(code);
  if (exact >= 0)
    return int(exact);
  const qsizetype dash = code.indexOf('-');
  return dash > 0 ? int(preferred.indexOf(code.left(dash))) : -1;
}
