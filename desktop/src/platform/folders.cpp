#include "folders.h"

#include <QDir>

namespace {

[[maybe_unused]] QString xdg(const char *variable, const QString &underHome) {
  const QString dir = qEnvironmentVariable(variable);
  return (dir.isEmpty() ? QDir::homePath() + "/" + underHome : dir) + "/lumeo";
}

} // namespace

QString Folders::config() {
#ifdef Q_OS_WIN
  return qEnvironmentVariable("APPDATA") + "/Lumeo";
#else
  return xdg("XDG_CONFIG_HOME", ".config");
#endif
}

QString Folders::cache() {
#ifdef Q_OS_WIN
  return qEnvironmentVariable("LOCALAPPDATA") + "/Lumeo/Cache";
#else
  return xdg("XDG_CACHE_HOME", ".cache");
#endif
}
