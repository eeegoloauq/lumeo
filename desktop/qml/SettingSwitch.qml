import QtQuick
import QtQuick.Controls
import Lumeo

// A switch named for what it switches, so it is announced as that.
Switch {
    id: control

    required property string label

    padding: 0
    implicitWidth: indicator.implicitWidth
    implicitHeight: indicator.implicitHeight
    focusPolicy: Qt.TabFocus
    Accessible.name: label
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    indicator: Rectangle {
        x: control.leftPadding
        y: (control.height - height) / 2
        implicitWidth: 42
        implicitHeight: 24
        radius: height / 2
        color: control.checked ? Theme.accent : Tokens.line
        border.width: control.visualFocus ? 2 : 0
        border.color: Tokens.text
        Behavior on color { ColorAnimation { duration: 120 } }

        Rectangle {
            x: control.checked ? parent.width - width - 3 : 3
            y: 3
            width: 18
            height: 18
            radius: 9
            color: control.checked ? Tokens.page : Tokens.dim
            Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        }
    }
    contentItem: null
}
