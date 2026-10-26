import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// A choice in a player menu: a check when it is the current one, the label,
// and at the right edge what tells it apart.
ItemDelegate {
    id: row

    property string label
    property string detail
    property bool current
    property bool indent
    // Beside the detail: a control of the row's own.
    default property alias trailing: extra.data

    implicitHeight: 36
    leftPadding: indent ? 28 : 12
    rightPadding: 12
    focusPolicy: Qt.NoFocus

    background: Rectangle { color: row.hovered ? "#14ffffff" : "transparent" }

    contentItem: RowLayout {
        spacing: 8

        Item {
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18

            Glyph {
                anchors.centerIn: parent
                visible: row.current
                glyph: "check"
                color: "white"
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.horizontalStretchFactor: 3
            text: row.label
            elide: Text.ElideRight
            color: row.current ? "white" : "#ccffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 14
            font.weight: row.current ? Font.DemiBold : Font.Normal
        }

        Text {
            Layout.fillWidth: true
            Layout.horizontalStretchFactor: 2
            visible: row.detail !== ""
            text: row.detail
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            color: "#80ffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 12
        }

        Row { id: extra }
    }
}
