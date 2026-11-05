pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Lumeo

// Release notes in a corner: what an update brought, or what a newer
// release would bring, under their headings (Added, Fixed and the like). A
// long list stops at six until its count is clicked, and scrolls when it is
// taller than the card's room; a [collapsed] card shows only the count, its
// notes having been told before.
CornerCard {
    id: card

    // Releases' groups: [{title, items}], an empty title for none.
    required property var groups
    required property string action
    property bool collapsed: false
    property bool all: false
    readonly property int count: groups.reduce((n, group) => n + group.items.length, 0)
    readonly property var shown: {
        let left = all ? count : collapsed ? 0 : 6
        const kept = []
        for (const group of groups) {
            if (left <= 0)
                break
            kept.push({title: group.title, items: group.items.slice(0, left)})
            left -= group.items.length
        }
        return kept
    }
    readonly property int hidden: count - shown.reduce((n, group) => n + group.items.length, 0)
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
                delegate: Column {
                    id: group
                    required property var modelData
                    width: list.width
                    spacing: 10
                    Text {
                        visible: group.modelData.title !== ""
                        width: parent.width
                        text: group.modelData.title
                        color: Tokens.text
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textData
                        font.weight: Font.DemiBold
                        wrapMode: Text.Wrap
                        Accessible.role: Accessible.Heading
                    }
                    Repeater {
                        model: group.modelData.items
                        delegate: Row {
                            id: item
                            required property string modelData
                            width: group.width
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
                }
            }
            RowButton {
                objectName: "moreNotes"
                visible: card.hidden > 0
                text: card.collapsed ? qsTrId("releaseChanges", card.hidden) : qsTrId("releaseMore", card.hidden)
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
