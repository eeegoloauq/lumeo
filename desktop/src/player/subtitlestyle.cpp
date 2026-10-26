#include "subtitlestyle.h"

#include <QVariantMap>
#include <utility>

namespace {

const std::pair<const char *, const char *> colours[] = {
    {"white", "#FFFFFF"},
    {"yellow", "#FFE14D"},
    {"cream", "#F5E6C4"},
    {"cyan", "#7FE0FF"},
};

} // namespace

QString SubtitleStyle::colour(const QString &name) {
  for (const auto &[known, value] : colours)
    if (name == QLatin1String(known))
      return value;
  return colours[0].second;
}

QVariantList SubtitleStyle::colourList() const {
  QVariantList list;
  for (const auto &[name, value] : colours)
    list.append(QVariantMap{{"name", name}, {"colour", value}});
  return list;
}
