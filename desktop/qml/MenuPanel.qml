import QtQuick

// What a player menu sits on, over the picture. It takes every click and
// wheel over it, so none of them reaches the film.
Rectangle {
    id: panel

    default property alias content: column.data

    implicitHeight: column.implicitHeight + 16
    radius: 12
    color: "#e01c1c1c"
    clip: true

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    Column {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
    }
}
