#pragma once

#include <QHash>
#include <QStringList>
#include <QVariant>

// What the core calls a language, against what a file calls it. A container
// writes ISO 639-2 on its tracks ("jpn", "ger" or "deu"), a muxer may add a
// BCP 47 tag ("en-US"), and a preference is ISO 639-1 with an optional
// region ("en", "pt-BR"). mpv joins those itself when it picks a track; what
// it lacks is a name for a code and the viewer's order, which this table,
// the core's own, gives (decisions/subtitles.md).
class Languages {
public:
  // The core's list: [{code, name, aliases}].
  explicit Languages(const QVariantList &list = {});

  // The preference code for whatever a track calls its language: "eng" and
  // "en-US" are both "en". A tag nothing here knows comes back lower-cased
  // rather than dropped: a track nobody can name is still a track.
  QString canonical(const QString &tag) const;
  // What to print for a tag; empty when nothing here names it.
  QString name(const QString &tag) const;
  // Where a tag sits in [preferred]: 0 for the first, -1 when absent. A
  // region satisfies a preference for its base ("pt-BR" for "pt").
  int rank(const QString &tag, const QStringList &preferred) const;

private:
  QHash<QString, QVariantMap> m_byCode;
  QHash<QString, QVariantMap> m_byAlias;
};
