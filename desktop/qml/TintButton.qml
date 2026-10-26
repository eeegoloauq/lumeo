import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// A round icon on a tint, beside Play: My list, share. Not in the accent,
// which marks what will play; the words are the tooltip.
AbstractButton {
    id: button

    required property string glyph
    property string tip

    implicitWidth: 36
    implicitHeight: 36
    focusPolicy: Qt.TabFocus
    opacity: enabled ? 1 : 0.4
    Accessible.name: tip
    ToolTip.text: tip
    ToolTip.visible: hovered && tip !== ""
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: width / 2
        color: button.down ? Qt.lighter(Tokens.tint, 1.4) : button.hovered ? Qt.lighter(Tokens.tint, 1.2) : Tokens.tint
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
    contentItem: Item {
        Glyph { anchors.centerIn: parent; glyph: button.glyph; size: 20 }
    }
}
