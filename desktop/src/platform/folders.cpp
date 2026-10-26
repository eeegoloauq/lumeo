#include "folders.h"

#include <QDir>
#include <QFile>

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

QString Folders::state() {
#ifdef Q_OS_WIN
  return qEnvironmentVariable("LOCALAPPDATA") + "/Lumeo/State";
#else
  return xdg("XDG_STATE_HOME", ".local/state");
#endif
}

QString Folders::playerLog() {
  const QString chosen = qEnvironmentVariable("LUMEO_MPV_LOG");
  return chosen.isEmpty() ? state() + "/mpv.log" : chosen;
}
