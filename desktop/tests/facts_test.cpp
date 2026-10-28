#include "language.h"
#include "mpvfacts.h"

#include <QtTest>

namespace {

QVariantMap binding(const QString &key, const QString &cmd, const QString &section = "default",
                    const QString &comment = {}) {
  return {{"key", key}, {"cmd", cmd}, {"section", section}, {"comment", comment}};
}

QStringList lines(const QVariantList &shortcuts) {
  QStringList out;
  for (const QVariant &line : shortcuts)
    out << line.toMap().value("keys").toStringList().join(", ") + " = " +
               line.toMap().value("what").toString();
  return out;
}

} // namespace

// What the headless mpv's answers come to, without an mpv.
class FactsTest : public QObject {
  Q_OBJECT

private slots:
  // One line per command, every key that does it; ours over mpv's for a
  // key; what has nothing to act on here left off.
  void theKeysAsTheShortcutPagePrintsThem() {
    const QVariantList bindings = {
        binding("SPACE", "cycle pause"),
        binding("p", "cycle pause"),
        binding("ESC", "set fullscreen no"),
        binding("ESC", "script-message lumeo escape", "lumeo"),
        binding("LEFT", "seek -5", "lumeo"),
        binding("LEFT", "seek -10", "default", "seek 10 seconds backward"),
        binding("Q", "quit-watch-later"),
        binding("q", "quit"),
        binding("WHEEL_UP", "add volume 2"),
        binding("PLAY", "cycle pause"),
        binding("z", "add sub-delay -0.1"),
        binding("x", "cycle-values video-aspect-override", "default", "cycle the aspect ratio"),
        binding("MBTN_LEFT", "cycle pause", "other"),
    };
    QCOMPARE(lines(MpvFacts::shortcuts(bindings)),
             QStringList({"Space, P = Pause or play", "Esc = Leave fullscreen, else back to the title",
                          "← = Seek 5 seconds backward", "Wheel up = Volume +2",
                          "Z = Show subtitles earlier", "X = Cycle the aspect ratio"}));
    QCOMPARE(lines(MpvFacts::shortcuts(bindings, {"z", "SPACE"})),
             QStringList({"Z = Show subtitles earlier", "Space, P = Pause or play"}));
  }

  // The page lists the arrows at the stored step, as the player binds them,
  // and mpv's exact seeks under the player's own binding of them.
  void theArrowsAtTheStoredStep() {
    const QVariantList bindings =
        QVariantList{binding("LEFT", "seek -5"), binding("RIGHT", "seek 5"),
                     binding("Shift+RIGHT", "no-osd seek 1 exact", "default", "seek exactly 1 second forward"),
                     binding("Shift+UP", "no-osd seek 5 exact", "default", "seek exactly 5 seconds forward")} +
        MpvFacts::ownBindingList(10);
    QCOMPARE(lines(MpvFacts::shortcuts(bindings, {"LEFT", "RIGHT", "Shift+RIGHT", "Shift+UP"})),
             QStringList({"← = Seek 10 seconds backward", "→ = Seek 10 seconds forward",
                          "Shift+→ = Seek exactly 1 second forward", "Shift+↑ = Seek 5 seconds forward"}));
  }

  void keysAsTheirKeycapsRead() {
    QCOMPARE(MpvFacts::keyLabel("f"), "F");
    QCOMPARE(MpvFacts::keyLabel("F"), "Shift+F");
    QCOMPARE(MpvFacts::keyLabel("Ctrl++"), "Ctrl++");
    QCOMPARE(MpvFacts::keyLabel("Alt+LEFT"), "Alt+←");
    QCOMPARE(MpvFacts::keyLabel("KP5"), "Numpad 5");
    QCOMPARE(MpvFacts::keyLabel("MBTN_LEFT_DBL"), "Double click");
    // Its purpose is printed on it.
    QCOMPARE(MpvFacts::keyLabel("VOLUME_UP"), "");
  }

  // h264 played by openh264 alone loses sync on a backward seek; with its
  // own decoder there, or a hardware wrapper beside it, nothing is said.
  void aDecoderKnownToBreak() {
    MpvFacts *facts = MpvFacts::instance();
    facts->setDecoders({QVariantMap{{"codec", "h264"}, {"driver", "libopenh264"}},
                        QVariantMap{{"codec", "h264"}, {"driver", "h264_cuvid"}},
                        QVariantMap{{"codec", "aac"}, {"driver", "aac"}}});
    QCOMPARE(facts->unreliable("h264"), "libopenh264");
    QCOMPARE(facts->has("hevc"), 0);
    facts->setDecoders({QVariantMap{{"codec", "h264"}, {"driver", "h264"}},
                        QVariantMap{{"codec", "h264"}, {"driver", "libopenh264"}}});
    QCOMPARE(facts->unreliable("h264"), "");
  }

  // The picture is reported before the sound; a name nobody knows is not a
  // missing decoder.
  void whatACopyWouldLoseHere() {
    MpvFacts *facts = MpvFacts::instance();
    facts->setDecoders({QVariantMap{{"codec", "h264"}}, QVariantMap{{"codec", "aac"}}});
    QCOMPARE(facts->gapIn({{"videoCodec", "HEVC"}, {"audioCodec", "DTS"}}),
             QVariantMap({{"codec", "hevc"}, {"sound", false}}));
    QCOMPARE(facts->gapIn({{"videoCodec", "AVC"}, {"audioCodec", "DTS-HD"}}),
             QVariantMap({{"codec", "dts"}, {"sound", true}}));
    QVERIFY(facts->gapIn({{"videoCodec", "AVC"}, {"audioCodec", "AAC"}}).isEmpty());
    QVERIFY(facts->gapIn({{"videoCodec", "Theora"}}).isEmpty());
    QCOMPARE(facts->gapMark({{"videoCodec", "HEVC"}}), "no hevc here");
  }

  void theDistributionFromOsRelease() {
    QVERIFY(MpvFacts::distributions("ID=fedora\nVERSION_ID=43\n").contains("fedora"));
    QVERIFY(MpvFacts::distributions("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n")
                .contains("suse"));
    QVERIFY(MpvFacts::distributions("# comment\nID=arch\n").contains("arch"));
  }
};

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  // The interface's English for the lines a test reads.
  installTranslations(QLocale(QLocale::English));
  FactsTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "facts_test.moc"
