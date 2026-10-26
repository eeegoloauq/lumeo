#include "mpvitem.h"
#include "playback.h"

#include <QtTest>

namespace {

// A key's PC scan code as Qt reports it here: Linux adds XKB's 8.
#ifdef Q_OS_WIN
constexpr quint32 board = 0;
#else
constexpr quint32 board = 8;
#endif
constexpr quint32 keyF = 0x21 + board;
constexpr quint32 key3 = 0x04 + board;

QString name(int key, const QString &text, Qt::KeyboardModifiers modifiers = {},
             quint32 scanCode = 0, const QSet<QString> &bound = {}) {
  return MpvItem::keyName(key, text, modifiers, scanCode, bound);
}

} // namespace

// What reaches mpv from the keyboard, and what is read from its lines,
// without an mpv: the player tests have the real one.
class MpvTest : public QObject {
  Q_OBJECT

private slots:
  void keysNamedByMpv() {
    QCOMPARE(name(Qt::Key_Space, " "), "SPACE");
    QCOMPARE(name(Qt::Key_Right, ""), "RIGHT");
    QCOMPARE(name(Qt::Key_Right, "", Qt::ShiftModifier), "Shift+RIGHT");
    QCOMPARE(name(Qt::Key_PageDown, ""), "PGDWN");
    QCOMPARE(name(Qt::Key_5, "5", Qt::KeypadModifier), "KP5");
    QCOMPARE(name(Qt::Key_MediaTogglePlayPause, ""), "PLAYPAUSE");
  }

  void charactersAsTyped() {
    QCOMPARE(name(Qt::Key_F, "f"), "f");
    QCOMPARE(name(Qt::Key_F, "F", Qt::ShiftModifier), "F");
    QCOMPARE(name(Qt::Key_BraceLeft, "{", Qt::ShiftModifier), "{");
    // mpv's input.conf reads # as a comment.
    QCOMPARE(name(Qt::Key_NumberSign, "#", Qt::ShiftModifier), "SHARP");
  }

  // With Ctrl the text is a control character; the key is the letter.
  void modifiersNameTheLetter() {
    QCOMPARE(name(Qt::Key_C, "\x03", Qt::ControlModifier), "Ctrl+c");
    QCOMPARE(name(Qt::Key_C, "\x03", Qt::ControlModifier | Qt::ShiftModifier), "Ctrl+C");
    QCOMPARE(name(Qt::Key_Left, "", Qt::AltModifier), "Alt+LEFT");
  }

  void aModifierAloneIsNoKey() {
    QCOMPARE(name(Qt::Key_Shift, "", Qt::ShiftModifier), "");
    QCOMPARE(name(Qt::Key_Control, "", Qt::ControlModifier), "");
  }

  // A Russian layout's а sits on f: unbound, it is f, as browsers and
  // players bind shortcuts to the physical key (decisions/player.md).
  void anotherLayoutsLetterIsTheKeyInItsPlace() {
    QCOMPARE(name(0x430, QString::fromUtf8("а"), {}, keyF), "f");
    QCOMPARE(name(0x410, QString::fromUtf8("А"), Qt::ShiftModifier, keyF), "F");
    QCOMPARE(name(0x2116, QString::fromUtf8("№"), Qt::ShiftModifier, key3), "SHARP");
    // A binding of the user's own for the letter keeps it.
    QCOMPARE(name(0x430, QString::fromUtf8("а"), {}, keyF, {QString::fromUtf8("а")}),
             QString::fromUtf8("а"));
  }

  void theCodecADecoderFailedFor() {
    QCOMPARE(Playback::decoderCodec("Failed to initialize a decoder for codec 'hevc'."), "hevc");
    QCOMPARE(Playback::decoderCodec("Cannot open file"), "");
  }
};

QTEST_GUILESS_MAIN(MpvTest)
#include "mpv_test.moc"
