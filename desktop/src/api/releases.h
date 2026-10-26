#pragma once

#include <QObject>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class Core;
class LocalSettings;
class QQmlEngine;
class QJSEngine;

// What an update brought and what a newer release would bring
// (decisions/shipping.md, Updates). The notes are AppStream's: this copy's
// own file and the newer release's, read in the interface's language. A beta
// has its own `<release version="X.Y.Z~beta.N">` with what it changed since
// the beta before, and the release's entry sums its betas up.
class Releases : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // This version's notes, for About.
  Q_PROPERTY(QStringList notes READ notes NOTIFY changed)
  // What the viewer has not been told since the version they last ran:
  // every release they skipped.
  Q_PROPERTY(QStringList news READ news NOTIFY changed)
  // The news was read before, told beta by beta or offered before it was
  // installed: its card shows only how many changes there are.
  Q_PROPERTY(bool newsTold READ newsTold NOTIFY changed)
  // A newer release, its page, and its notes since this version; an empty
  // version is none.
  Q_PROPERTY(QString update READ update NOTIFY changed)
  Q_PROPERTY(QString updateUrl READ updateUrl NOTIFY changed)
  Q_PROPERTY(QStringList updateNotes READ updateNotes NOTIFY changed)

public:
  Releases(Core *core, LocalSettings *settings, const QString &version, const QString &bundled,
           QObject *parent = nullptr);
  static Releases *create(QQmlEngine *qml, QJSEngine *);

  QStringList notes() const { return between(m_bundled, {}, m_version, m_language); }
  QStringList news() const;
  bool newsTold() const;
  QString update() const { return m_update; }
  QString updateUrl() const { return m_updateUrl; }
  QStringList updateNotes() const { return between(m_updateSource, m_version, m_update, m_language); }

  // Asks the core for a newer release, which it looks up at most once a
  // day. A failed look is no news: the core logs why.
  Q_INVOKABLE void check();
  // The newer release's notice was closed: that version stays quiet, and so
  // does any other for a week, since releases can come several a day.
  Q_INVOKABLE void dismissUpdate();
  // This version's news was shown.
  Q_INVOKABLE void seen();
  // The interface's language code, which the notes are read in.
  void setLanguage(const QString &language);

  // The items of every release after [after] up to [through], newest first.
  // Betas count only on the way to a beta: a release's own entry already
  // sums its betas up. An [after] that is not a version gives [through]
  // alone.
  static QStringList between(const QString &source, const QString &after, const QString &through,
                             const QString &language);
  // Whether [seen] is a beta of [version], whose betas told what it sums up.
  static bool toldInBetas(const QString &seen, const QString &version);

  // How long a closed notice keeps the next ones away.
  static constexpr int quietDays = 7;

signals:
  void changed();

private:
  Core *m_core;
  LocalSettings *m_settings;
  QString m_version;
  QString m_bundled;
  QString m_language = "en";
  QString m_update;
  QString m_updateUrl;
  QString m_updateSource;
};
