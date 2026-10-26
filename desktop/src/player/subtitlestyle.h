#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

// How plain-text subtitles are drawn, in mpv's 720-line scale: the player
// sets mpv from these, and Settings draws its sample line from the same.
class SubtitleStyle : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // The colours the `subtitleColor` preference names, as {name, colour}.
  Q_PROPERTY(QVariantList colours READ colourList CONSTANT)
  // The sizes offered, as `subtitleScale`.
  Q_PROPERTY(QVariantList scales READ scaleList CONSTANT)
  Q_PROPERTY(int fontSize READ fontSizeValue CONSTANT)
  Q_PROPERTY(int margin READ marginValue CONSTANT)
  Q_PROPERTY(int shadow READ shadowValue CONSTANT)
  Q_PROPERTY(QString boxColour READ boxColourValue CONSTANT)

public:
  // A line 1/15 of the picture high, 1/20 of it above the bottom edge,
  // where a streaming release's styled dialogue sits, so the two read alike.
  static constexpr int fontSize = 48;
  static constexpr int margin = 36;
  // The drop shadow moves the outlined line down and right, opaque and
  // unblurred: a wide translucent one reads as a grey smear.
  static constexpr int shadow = 3;
  static constexpr const char *boxColour = "#C0000000";

  // White, a broadcast yellow, a softer cream for long sittings, and a cyan
  // that stays apart from warm pictures; white for a name it does not know.
  static QString colour(const QString &name);
  // A thick outline alone; a thin one under a drop shadow, which a thick one
  // would hide; for the box, its padding.
  Q_INVOKABLE static double border(const QString &background) {
    return background == "shadow" ? 1.5 : 4.0;
  }

  QVariantList colourList() const;
  QVariantList scaleList() const { return {0.8, 1.0, 1.25, 1.5}; }
  int fontSizeValue() const { return fontSize; }
  int marginValue() const { return margin; }
  int shadowValue() const { return shadow; }
  QString boxColourValue() const { return boxColour; }
};
