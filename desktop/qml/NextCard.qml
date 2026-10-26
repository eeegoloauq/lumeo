import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// The next episode, offered over the credits or the held last frame: its
// still, a ring that fills as the countdown runs, and its name. A press
// starts it.
AbstractButton {
    id: card

    required property var episode
    property string stills: "show"
    // A frame from its file on disk, when it has no still.
    property string frame
    property real fill
    // Seconds until it starts by itself; -1 when it waits for a press.
    property int secondsLeft: -1

    implicitWidth: 340
    implicitHeight: column.implicitHeight
    focusPolicy: Qt.NoFocus
    hoverEnabled: true
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: 12
        color: card.hovered ? "#f02a2a2a" : "#e01c1c1c"
    }

    contentItem: Column {
        id: column

        EpisodeStill {
            width: card.width
            height: 180
            episode: card.episode
            stills: card.stills
            frame: card.frame

            // Fills between the steps the position arrives in.
            Item {
                anchors.centerIn: parent
                width: 56
                height: 56
                visible: card.secondsLeft >= 0

                ProgressRing {
                    anchors.fill: parent
                    fraction: card.fill
                    stroke: 3
                    color: "white"
                    Behavior on fraction { NumberAnimation { duration: 250 } }
                }
            }

            Glyph { anchors.centerIn: parent; glyph: "play_arrow"; size: 30; color: "white" }
        }

        Column {
            width: card.width
            padding: 12
            spacing: 3

            Text {
                text: card.secondsLeft >= 0 ? qsTrId("playerNextIn", card.secondsLeft) : qsTrId("playerNextEpisode")
                color: "#aaaaaa"
                font.family: Tokens.fontSans
                font.pixelSize: 12
            }

            Text {
                width: parent.width - 24
                text: Words.episodeName(card.episode)
                elide: Text.ElideRight
                color: "white"
                font.family: Tokens.fontSans
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
        }
    }
}
