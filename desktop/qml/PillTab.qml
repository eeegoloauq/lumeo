import QtQuick
import QtQuick.Controls
import Lumeo

// A place, not an action: lit when the window is there. The bar's tabs, and
// places within a page.
AbstractButton {
    id: tab

    property bool lit

    implicitHeight: 34
    implicitWidth: label.implicitWidth + 32
    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    checkable: false
    checked: lit

    // A tint rather than a surface: a solid pill on a dark frame is a hole.
    background: Rectangle {
        radius: height / 2
        color: tab.lit ? Tokens.tint : tab.down || tab.hovered ? Tokens.hover : "transparent"
        border.width: tab.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
    contentItem: Text {
        id: label
        text: tab.text
        color: tab.lit ? Tokens.text : Tokens.dim
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textCard
        font.weight: Font.DemiBold
        font.letterSpacing: 0.1
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
