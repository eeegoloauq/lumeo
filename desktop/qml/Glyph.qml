import QtQuick
import Lumeo

// An icon of icons/ outside a button, in [color], tinted as it is loaded
// (glyphs.h).
Image {
    id: icon

    required property string glyph
    property real size: 18
    property color color: Tokens.text

    source: glyph ? "image://glyph/" + glyph + "/" + String(color).slice(1) : ""
    sourceSize: Qt.size(size, size)
}
