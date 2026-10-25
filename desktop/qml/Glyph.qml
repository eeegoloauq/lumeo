pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Lumeo

// An icon of icons/ outside a button, in [color]: the SVGs are drawn black,
// lifted to white and tinted.
Image {
    id: icon

    required property string glyph
    property real size: 18
    property color color: Tokens.text

    source: "qrc:/qt/qml/Lumeo/icons/" + glyph + ".svg"
    sourceSize: Qt.size(size, size)
    layer.enabled: true
    layer.effect: MultiEffect {
        brightness: 1
        colorization: 1
        colorizationColor: icon.color
    }
}
