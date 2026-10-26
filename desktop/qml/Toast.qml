import QtQuick
import QtQuick.Controls
import Lumeo

// A line at the foot of a page for a few seconds, or for as long as [held],
// with a button when it offers one.
Rectangle {
    id: toast
    objectName: "toast"

    // What say() was given; a page may show something else while held.
    property string said
    property string text: said
    property bool held: false
    // The button's label; empty for none.
    property string action
    signal acted()

    function say(text) {
        said = text
        timer.restart()
    }

    anchors { bottom: parent.bottom; bottomMargin: 32; horizontalCenter: parent.horizontalCenter }
    visible: held || timer.running
    width: row.implicitWidth + 28
    height: 52
    radius: Tokens.radiusFloating
    color: Tokens.floating
    border.color: Tokens.rim

    Timer { id: timer; interval: 4000 }

    Row {
        id: row
        anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
        spacing: 18

        Text {
            anchors.verticalCenter: parent.verticalCenter
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
