pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// Audio and subtitles in one panel, side by side: whoever picks Japanese
// audio is about to look for English subtitles (decisions/subtitles.md).
// Size, height, timing and the edge are a page of their own.
MenuPanel {
    id: menu

    required property Tracks tracks
    // How tall it may grow: the window less the bar.
    property real room: 600
    property bool style: false

    // A pick was made: the menu goes.
    signal done()

    readonly property var scales: [0.8, 1.0, 1.25, 1.5]

    width: style ? 340 : 520
    // The page on show decides, not the hidden one.
    implicitHeight: (style ? stylePage.height : lists.height + note.height) + 16
    height: Math.min(implicitHeight, room)

    // The two columns, and what the database lookup came to under both.
    Item {
        id: lists
        visible: !menu.style
        width: menu.width
        height: visible ? Math.min(Math.max(audioColumn.implicitHeight, subtitleColumn.implicitHeight),
                                   menu.room - 16 - (note.visible ? note.height : 0)) : 0

        RowLayout {
            anchors.fill: parent
            spacing: 0

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                contentHeight: audioColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Column {
                    id: audioColumn
                    width: parent.width

                    MenuLabel { width: parent.width; text: qsTrId("playerAudio") }

                    Text {
                        visible: audioRows.count === 0
                        x: 16
                        width: parent.width - 28
                        topPadding: 16
                        bottomPadding: 8
                        text: qsTrId("playerNoSound")
                        wrapMode: Text.Wrap
                        color: "#ccffffff"
                        font.family: Tokens.fontSans
                        font.pixelSize: 14
                    }

                    Repeater {
                        id: audioRows
                        model: menu.tracks.audio
                        delegate: MenuRow {
                            required property string track
                            required label
                            required detail
                            required current
                            objectName: "audio-" + track
                            width: audioColumn.width
                            onClicked: {
                                menu.tracks.pickAudio(track)
                                menu.done()
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillHeight: true; Layout.preferredWidth: 1; color: "#30ffffff" }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                contentHeight: subtitleColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Column {
                    id: subtitleColumn
                    width: parent.width

                    MenuLabel {
                        width: parent.width
                        text: qsTrId("playerSubtitles")

                        IconButton {
                            objectName: "subtitleStyle"
                            implicitWidth: 32
                            implicitHeight: 32
                            glyph: "tune"
                            tone: "white"
                            focusPolicy: Qt.NoFocus
                            tip: qsTrId("playerSubtitleStyle")
                            onClicked: menu.style = true
                        }
                    }

                    Repeater {
                        model: menu.tracks.subtitles
                        delegate: MenuRow {
                            id: row
                            required property string kind
                            required property string track
                            required property int found
                            required property int more
                            required property string group
                            required label
                            required detail
                            required current
                            required indent
                            objectName: kind === "off" ? "subtitlesOff"
                                : kind === "track" ? "subtitle-" + track
                                : "found-" + found
                            width: subtitleColumn.width
                            enabled: kind !== "note"
                            onClicked: {
                                if (kind === "off")
                                    menu.tracks.pickSubtitle("")
                                else if (kind === "track")
                                    menu.tracks.pickSubtitle(track)
                                else
                                    menu.tracks.pickFound(found)
                                menu.done()
                            }

                            // The database's other copies of this language.
                            Button {
                                objectName: "more-" + row.group
                                visible: row.more > 0
                                flat: true
                                focusPolicy: Qt.NoFocus
                                implicitHeight: 28
                                padding: 0
                                leftPadding: 6
                                rightPadding: 6
                                text: qsTrId("playerMoreTracks", row.more)
                                font.family: Tokens.fontSans
                                font.pixelSize: 12
                                palette.buttonText: "#80ffffff"
                                onClicked: menu.tracks.expand(row.group)
                            }
                        }
                    }
                }
            }
        }
    }

    // Under both columns: it is about the search, not one more subtitle.
    RowLayout {
        id: note
        visible: !menu.style && menu.tracks.note !== ""
        width: menu.width
        height: visible ? 46 : 0
        spacing: 12

        Text {
            objectName: "searchNote"
            Layout.fillWidth: true
            Layout.leftMargin: 16
            text: menu.tracks.note
            elide: Text.ElideRight
            color: "#80ffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 12
        }

        Button {
            id: again
            Layout.rightMargin: 12
            focusPolicy: Qt.NoFocus
            implicitHeight: 30
            leftPadding: 12
            rightPadding: 12
            text: qsTrId("playerSearchAgain")
            font.family: Tokens.fontSans
            font.pixelSize: 13
            font.weight: Font.Medium
            palette.buttonText: "white"
            background: Rectangle {
                radius: 15
                color: again.hovered ? "#14ffffff" : "transparent"
                border.color: "#4dffffff"
            }
            onClicked: menu.tracks.lookUp()
        }
    }

    // The style page.
    Column {
        id: stylePage
        visible: menu.style
        width: menu.width

        ItemDelegate {
            id: back
            width: parent.width
            implicitHeight: 44
            focusPolicy: Qt.NoFocus
            leftPadding: 12
            background: Rectangle { color: back.hovered ? "#14ffffff" : "transparent" }
            contentItem: Row {
                spacing: 8
                Glyph { anchors.verticalCenter: parent.verticalCenter; glyph: "chevron_left"; size: 20; color: "white" }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTrId("playerSubtitleStyle")
                    color: "white"
                    font.family: Tokens.fontSans
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }
            }
            onClicked: menu.style = false
        }

        Rectangle { width: parent.width; height: 1; color: "#1fffffff" }

        StyleLine {
            label: qsTrId("playerSize")
            Repeater {
                model: [qsTrId("playerSizeS"), qsTrId("playerSizeM"), qsTrId("playerSizeL"), qsTrId("playerSizeXl")]
                delegate: Choice {
                    required property string modelData
                    required property int index
                    objectName: "size-" + index
                    text: modelData
                    on: Math.abs(menu.tracks.scale - menu.scales[index]) < 0.01
                    onClicked: menu.tracks.setScale(menu.scales[index])
                }
            }
        }

        StyleLine {
            label: qsTrId("playerPosition")
            Stepper {
                value: menu.tracks.position >= 100 ? qsTrId("playerBottom")
                    : qsTrId("playerPositionUp").arg(Math.round(100 - menu.tracks.position))
                onLess: menu.tracks.setPosition(menu.tracks.position + 5)
                onMore: menu.tracks.setPosition(menu.tracks.position - 5)
            }
        }

        StyleLine {
            label: qsTrId("playerTiming")
            Stepper {
                objectName: "timing"
                value: Math.abs(menu.tracks.delay) < 0.05 ? qsTrId("playerInSync")
                    : qsTrId("playerTimingOffset").arg((menu.tracks.delay > 0 ? "+" : "")
                        + Number(menu.tracks.delay).toLocaleString(Qt.locale(), "f", 1))
                onLess: menu.tracks.setDelay(menu.tracks.delay - 0.1)
                onMore: menu.tracks.setDelay(menu.tracks.delay + 0.1)
            }
        }

        StyleLine {
            label: qsTrId("playerBackground")
            Repeater {
                model: [["none", qsTrId("playerOutline")], ["shadow", qsTrId("playerShadow")], ["box", qsTrId("playerBox")]]
                delegate: Choice {
                    required property var modelData
                    objectName: "background-" + modelData[0]
                    text: modelData[1]
                    on: menu.tracks.background === modelData[0]
                    onClicked: menu.tracks.setBackground(modelData[0])
                }
            }
        }
    }

    component StyleLine: Item {
        id: line
        property string label
        default property alias control: controls.data
        width: menu.width
        implicitHeight: 48

        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: line.label
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 14
        }

        Row {
            id: controls
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
        }
    }

    component Choice: Button {
        id: choice
        property bool on
        focusPolicy: Qt.NoFocus
        implicitHeight: 32
        implicitWidth: Math.max(36, contentItem.implicitWidth + 16)
        font.family: Tokens.fontSans
        font.pixelSize: 14
        palette.buttonText: "white"
        background: Rectangle {
            radius: 6
            color: choice.on ? "#2effffff" : choice.hovered ? "#14ffffff" : "transparent"
        }
    }

    component Stepper: Row {
        id: stepper
        property string value
        signal less()
        signal more()

        IconButton { glyph: "remove"; tone: "white"; focusPolicy: Qt.NoFocus; onClicked: stepper.less() }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 80
            horizontalAlignment: Text.AlignHCenter
            text: stepper.value
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 14
        }
        IconButton { glyph: "add"; tone: "white"; focusPolicy: Qt.NoFocus; onClicked: stepper.more() }
    }
}
