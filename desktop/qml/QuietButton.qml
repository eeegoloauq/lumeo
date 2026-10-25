import QtQuick
import QtQuick.Controls
import Lumeo

// Every other action beside the play button: an edge, no fill.
Button {
    id: button

    implicitHeight: 52
    leftPadding: 22
    rightPadding: 22
    focusPolicy: Qt.TabFocus
    font.family: Tokens.fontSans
    font.pixelSize: 15
    font.weight: Font.DemiBold
    font.letterSpacing: 0.1
    palette.buttonText: Tokens.text

    background: Rectangle {
        radius: Tokens.radiusControl
        color: button.down ? Tokens.tint : button.hovered ? Tokens.hover : "transparent"
        border.width: button.visualFocus ? 2 : 1
        border.color: button.visualFocus ? Theme.accent : Tokens.line
    }

    HoverHandler { cursorShape: Qt.PointingHandCursor }
}
