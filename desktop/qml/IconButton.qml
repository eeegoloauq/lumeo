import QtQuick
import QtQuick.Controls
import Lumeo

// An icon in a circle that only shows under the pointer, with its words in
// the tooltip.
AbstractButton {
    id: button

    property int glyph
    property real glyphSize: 18
    property color tone: Tokens.text
    property string tip

    implicitWidth: 34
    implicitHeight: 34
    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    Accessible.name: tip
    ToolTip.text: tip
    ToolTip.visible: hovered && tip !== ""
    ToolTip.delay: 500

    background: Rectangle {
        radius: height / 2
        color: button.down || button.hovered ? Tokens.hover : "transparent"
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
    contentItem: Icon {
        glyph: button.glyph
        size: button.glyphSize
        color: button.tone
    }
}
