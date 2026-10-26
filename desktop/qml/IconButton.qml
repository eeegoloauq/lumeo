import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// An icon in a circle that only shows under the pointer, with its words in
// the tooltip. The icon is one of icons/, drawn in [tone].
ToolButton {
    id: button

    property string glyph
    property real glyphSize: 18
    property color tone: Tokens.text
    property string tip

    implicitWidth: 34
    implicitHeight: 34
    padding: 0
    focusPolicy: Qt.TabFocus
    display: AbstractButton.IconOnly
    icon.source: "qrc:/qt/qml/Lumeo/icons/" + glyph + ".svg"
    icon.width: glyphSize
    icon.height: glyphSize
    icon.color: tone
    Accessible.name: tip
    ToolTip {
        text: button.tip
        visible: button.hovered && button.tip !== ""
    }

    background: Rectangle {
        radius: height / 2
        color: button.down || button.hovered ? Tokens.hover : "transparent"
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
}
