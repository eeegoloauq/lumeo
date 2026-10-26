import QtQuick
import QtQuick.Layouts
import Lumeo

// A section's name in a player menu, with a control of its own at the end.
Item {
    id: label

    property string text
    default property alias trailing: extra.data

    implicitHeight: 40

    RowLayout {
        anchors { fill: parent; leftMargin: 16; rightMargin: 8 }

        Text {
            Layout.fillWidth: true
            text: label.text.toUpperCase()
            color: "#8cffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 12
            font.letterSpacing: 0.72
        }

        Row { id: extra }
    }
}
