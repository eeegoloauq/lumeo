import QtQuick
import QtQuick.Controls
import Lumeo

// The one action the whole product is built around: one on a screen, in the
// accent (decisions/interface.md).
Button {
    id: button

    implicitHeight: 52
    leftPadding: 22
    rightPadding: 22
    spacing: 8
    focusPolicy: Qt.TabFocus
    font.family: Tokens.fontSans
    font.pixelSize: 15
    font.weight: Font.DemiBold
    font.letterSpacing: 0.1
    icon.source: "qrc:/qt/qml/Lumeo/icons/play_arrow.svg"
    icon.width: 22
    icon.height: 22
    icon.color: Tokens.page
    palette.buttonText: Tokens.page
    // Nothing to play: present, so the page does not shift, but out.
    opacity: enabled ? 1 : 0.4

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Theme.accent

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Tokens.page
            opacity: button.down ? 0.1 : button.hovered ? 0.08 : 0
        }
        // Outside the fill, which is the accent the ring is drawn in.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -4
            radius: parent.radius + 4
            color: "transparent"
            visible: button.visualFocus
            border.width: 2
            border.color: Theme.accent
        }
    }

    HoverHandler { cursorShape: Qt.PointingHandCursor }
}
