import QtQuick
import Lumeo

// A glyph of Material's icon font, by codepoint.
Text {
    property int glyph
    property real size: 18

    text: String.fromCodePoint(glyph)
    font.family: "Material Icons"
    font.pixelSize: size
    color: Tokens.text
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
