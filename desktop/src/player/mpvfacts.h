#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// What this machine's mpv can do, asked once of an mpv with no file: the
// decoders it has, its own key bindings, its version. A title page needs the
// decoders before anything plays, and the settings page has no film to ask
// (decisions/sources.md, decisions/player.md).
class MpvFacts : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // mpv answered; until then nothing is claimed about decoders or keys.
  Q_PROPERTY(bool answered READ answered NOTIFY changed)
  // mpv's own bindings, [{key, cmd, comment, section}].
  Q_PROPERTY(QVariantList bindings READ bindings NOTIFY changed)
  // "0.41.0"; empty when unknown.
  Q_PROPERTY(QString version READ version NOTIFY changed)
  // The hardware decoder the last film used, as mpv names it; empty before
  // one played, or when it decoded in software.
  Q_PROPERTY(QString hardware READ hardware NOTIFY changed)
  // How to add a missing decoder here, where they are packaged apart.
  Q_PROPERTY(QString installHint READ installHint NOTIFY changed)
  Q_PROPERTY(QStringList installCommands READ installCommands NOTIFY changed)
  // yt-dlp is on the PATH, which mpv runs to play a trailer's link; a test
  // says so in place of the machine.
  Q_PROPERTY(bool ytdl MEMBER m_ytdl NOTIFY changed)

public:
  // The one everything reads, asked as the application starts.
  static MpvFacts *instance();
  static MpvFacts *create(QQmlEngine *, QJSEngine *);

  bool answered() const { return m_answered; }
  QVariantList bindings() const { return m_bindings; }
  QString version() const { return m_version; }
  QString hardware() const { return m_hardware; }
  void setHardware(const QString &hwdec);
  QString installHint() const;
  QStringList installCommands() const;

  // Whether this machine has a decoder for one of mpv's codec names: 1 or
  // 0, and -1 while that is unknown. Unknown is never "none".
  Q_INVOKABLE int has(const QString &codec) const;
  // What this machine decodes, as mpv's decoder-list: a test says so in place
  // of mpv.
  Q_INVOKABLE void setDecoders(const QVariantList &decoderList);
  // What a copy would lose here, by the codecs its name states: {codec,
  // sound}, the picture before the sound; empty when it plays or nobody
  // knows.
  Q_INVOKABLE QVariantMap gapIn(const QVariantMap &release) const;
  // The same, said: a row's mark ("mark") and the whole of it ("sentence").
  Q_INVOKABLE QString gapMark(const QVariantMap &release) const;
  Q_INVOKABLE QString gapSentence(const QVariantMap &release) const;
  // What mpv's ytdl hook asks yt-dlp for, as ytdl-format: the tallest
  // picture up to [height] (0 for any), VP9 where there is one.
  Q_INVOKABLE static QString trailerFormat(int height);
  // The decoder a codec is played with when it is one known to break: Fedora
  // without the freeworld codecs plays h264 with openh264, which loses sync
  // on a backward seek. Empty when its own decoder is here.
  Q_INVOKABLE QString unreliable(const QString &codec) const;

  // mpv's names for what a release's name states; empty for a name nobody
  // here knows, which is not a missing decoder.
  static QString videoCodec(const QString &release);
  static QString audioCodec(const QString &release);
  // mpv's decoder list as codec names against the drivers offered for each.
  static QHash<QString, QSet<QString>> drivers(const QVariantList &decoderList);
  // The distribution families /etc/os-release names.
  static QSet<QString> distributions(const QString &osRelease);
  // The lines of the keyboard page: [{keys, what}], one per command, with
  // every key that does it. [bindings] are mpv's input-bindings; ours win
  // over its defaults for a key. With [only], the lines for what those keys
  // do, in that order.
  static QVariantList shortcuts(const QVariantList &bindings, const QStringList &only = {});
  // The player's own bindings over mpv's, as `define-section` takes them:
  // its actions, and the arrows at the stored step so that mpv seeks.
  static QStringList ownBindings(int seekStep);
  // The same as input-bindings lists them.
  static QVariantList ownBindingList(int seekStep);
  // The keyboard page of the settings: mpv's bindings and ours, the keys
  // most people reach for unless [all].
  Q_INVOKABLE QVariantList shortcutLines(int seekStep, bool all) const;
  // A key as its keycap reads; empty for media and power keys, whose purpose
  // is printed on them.
  static QString keyLabel(const QString &key);

signals:
  void changed();

private:
  explicit MpvFacts(QObject *parent = nullptr);
  void ask();

  bool m_answered = false;
  QHash<QString, QSet<QString>> m_drivers;
  QVariantList m_bindings;
  QString m_version;
  QString m_hardware;
  QString m_osRelease;
  bool m_ytdl = false;
};
