import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// A line at the foot of a page for a few seconds, or for as long as [held],
// with a button when it offers one. A line too long for the window wraps.
Rectangle {
    id: toast
    objectName: "toast"

    // What say() was given; a page may show something else while held.
    property string said
    property string text: said
    property bool held: false
    // The button's label; empty for none.
    property string action
    // Qt.BottomEdge or Qt.TopEdge, [margin] from it.
    property int edge: Qt.BottomEdge
    property real margin: 32
    // How long a line stays, in ms.
    property int lasts: 4000
    signal acted()

    function say(text) {
        said = text
        timer.restart()
    }

    anchors {
        top: edge === Qt.TopEdge ? parent.top : undefined
        topMargin: margin
        bottom: edge === Qt.BottomEdge ? parent.bottom : undefined
        bottomMargin: margin
        horizontalCenter: parent.horizontalCenter
    }
    visible: held || timer.running
    width: row.implicitWidth + 36
    height: Math.max(52, row.implicitHeight + 20)
    radius: Tokens.radiusFloating
    color: Tokens.floating
    border.color: Tokens.rim

    Timer { id: timer; interval: toast.lasts }

    Row {
        id: row
        anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
        spacing: 18

        Text {
            objectName: "toastText"
            // What the window leaves beside its sides' 24 px and the button.
            readonly property real room: (toast.parent?.width ?? 0) - 48 - 36
                                         - (button.visible ? button.implicitWidth + row.spacing : 0)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, room)
            wrapMode: Text.Wrap
            text: toast.text
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textCard
        }
        AbstractButton {
            id: button
            objectName: "toastAction"
            anchors.verticalCenter: parent.verticalCenter
            visible: toast.action !== ""
            implicitHeight: 32
            implicitWidth: label.implicitWidth + 28
            focusPolicy: Qt.TabFocus
            hoverEnabled: true
            onClicked: toast.acted()
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            background: Rectangle {
                radius: Tokens.radiusControl
                color: button.down || button.hovered ? Qt.lighter(Tokens.tint, 1.3) : Tokens.tint
                border.width: button.visualFocus ? 2 : 0
                border.color: Theme.accent
            }
            contentItem: Text {
                id: label
                text: toast.action
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
