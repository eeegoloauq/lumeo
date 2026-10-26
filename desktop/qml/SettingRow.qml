import QtQuick
import QtQuick.Layouts
import Lumeo

// One line of the settings page: its name, a hint under it only for a
// consequence the name cannot carry, and the control at the card's right
// edge, so the controls of a section read as one column. On a narrow page
// they go under the name.
Item {
    id: row

    required property string label
    property string hint
    default property alias control: controls.data

    readonly property bool narrow: width < 560

    width: parent?.width ?? 0
    implicitHeight: Math.max(60, content.implicitHeight + 20)

    // Between rows, none above the first: a row is a line of a list, not an
    // object with an edge.
    Rectangle {
        visible: row.y > 0
        width: parent.width
        height: 1
        color: Tokens.divider
    }

    GridLayout {
        id: content
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        columns: row.narrow ? 1 : 2
        columnSpacing: 24
        rowSpacing: 10

        Column {
            Layout.fillWidth: true
            Layout.preferredWidth: row.narrow ? content.width : 232
            spacing: 3

            Text {
                width: parent.width
                text: row.label
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 14
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }
            Text {
                width: Math.min(parent.width, 420)
                visible: row.hint !== ""
                text: row.hint
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }
        RowLayout {
            id: controls
            Layout.alignment: row.narrow ? Qt.AlignLeft : Qt.AlignRight
            spacing: 12
        }
    }
}
