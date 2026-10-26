pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// Release notes in a corner: what an update brought, or what a newer
// release would bring. A long list stops at six until its count is clicked,
// and scrolls when it is taller than the card's room; a [collapsed] card
// shows only the count, its notes having been told before.
CornerCard {
    id: card

    required property var items
    required property string action
    property bool collapsed: false
    property bool all: false
    readonly property var shown: all ? items : items.slice(0, collapsed ? 0 : 6)
    signal acted()

    Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: list.implicitHeight
        contentHeight: list.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: list
            width: parent.width
            spacing: 10

            Repeater {
                model: card.shown
                delegate: Row {
                    id: item
                    required property string modelData
                    width: list.width
                    spacing: 10
                    Rectangle {
                        y: 7
                        width: 5
                        height: 5
                        radius: 2.5
                        color: Tokens.dim
                    }
                    Text {
                        width: parent.width - 15
                        text: item.modelData
                        color: Tokens.dim
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textData
                        wrapMode: Text.Wrap
                    }
                }
            }
            RowButton {
                objectName: "moreNotes"
                readonly property int hidden: card.items.length - card.shown.length
                visible: hidden > 0
                text: card.collapsed ? qsTrId("releaseChanges", hidden) : qsTrId("releaseMore", hidden)
                onClicked: card.all = true
            }
        }
    }

    buttons: [
        RowButton {
            objectName: "releaseAction"
            text: card.action
            onClicked: card.acted()
        },
        RowButton {
            text: qsTrId("releaseAllChanges")
            onClicked: Qt.openUrlExternally("https://github.com/eeegoloauq/lumeo/releases")
        }
    ]
}
