pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Lumeo

// The player's keys, read from mpv and ours, not edited here: mpv owns them.
SettingsBlock {
    id: block

    property bool all

    readonly property var lines: MpvFacts.answered
        ? MpvFacts.shortcutLines(Preferences.current.seekStep ?? 5, all) : []
    // Two columns where there is room for them.
    readonly property int columns: width < 560 ? 1 : 2

    title: qsTrId("settingsShortcuts")
    section: "shortcuts"

    SettingsCard {
        Item { width: 1; height: 4 }
        Text {
            visible: !MpvFacts.answered
            width: parent.width
            topPadding: 18
            bottomPadding: 18
            text: qsTrId("settingsNoShortcuts")
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
        }

        GridLayout {
            objectName: "shortcuts"
            visible: MpvFacts.answered
            width: parent.width
            columns: block.columns
            columnSpacing: 40
            rowSpacing: 0
            flow: GridLayout.TopToBottom
            rows: Math.ceil(block.lines.length / block.columns)

            Repeater {
                model: block.lines
                delegate: Item {
                    id: line
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: 44
                    Accessible.role: Accessible.StaticText
                    Accessible.name: modelData.what + ": " + modelData.keys.join(", ")

                    Text {
                        anchors { left: parent.left; right: keys.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: line.modelData.what
                        color: Tokens.dim
                        font.family: Tokens.fontSans
                        font.pixelSize: 14
                        elide: Text.ElideRight
                    }
                    Row {
                        id: keys
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 6

                        Repeater {
                            model: line.modelData.keys
                            delegate: Rectangle {
                                required property string modelData
                                width: Math.max(26, cap.implicitWidth + 14)
                                height: 26
                                radius: Tokens.radiusControl
                                color: Tokens.raised
                                border.color: "#2f3037"

                                // The key's lower edge, as a keycap has one.
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    anchors.margins: 1
                                    height: 2
                                    radius: 1
                                    color: "#2f3037"
                                }
                                Text {
                                    id: cap
                                    anchors.centerIn: parent
                                    text: parent.modelData
                                    color: Tokens.text
                                    font.family: Tokens.fontSans
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                }
                            }
                        }
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: Tokens.divider
                    }
                }
            }
        }
        Item { width: 1; height: 14 }
        RowButton {
            objectName: "allKeys"
            visible: MpvFacts.answered
            text: block.all ? qsTrId("settingsFewerKeys") : qsTrId("settingsAllPlayerKeys")
            onClicked: block.all = !block.all
        }
        Item { width: 1; height: 16 }
    }
}
