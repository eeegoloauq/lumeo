import QtQuick
import QtQuick.Controls
import Lumeo
import "format.js" as Format

// One episode in a season's strip: its still and its name, no synopsis,
// which spoils the episode about to be played. A click or the keyboard
// arriving chooses it; the button on the still under the pointer, or
// Enter, plays it (decisions/interface.md).
AbstractButton {
    id: card

    required property var episode
    property bool selected
    // How the still is shown: "show", "blur" until watched, or "hide".
    property string stills: "show"
    // The share watched, a full bar once watched; 0 for none.
    property real bar
    property bool watched
    // One of Downloads.marks, or undefined.
    property var mark
    // Out, but nothing can fetch it and it is not on disk.
    property bool unreachable

    signal chosen()
    signal played()
    // Left or right from this card, by one.
    signal step(int by)

    readonly property bool upcoming: !!episode.released && new Date(episode.released) > new Date()
    readonly property string named: episode.title && episode.title !== "Episode " + episode.number
                                    ? episode.title : ""

    implicitWidth: 300
    implicitHeight: 300 * 9 / 16 + 64
    hoverEnabled: true
    Accessible.name: named ? qsTrId("itemEpisodeNamed").arg(episode.number).arg(named)
                           : qsTrId("itemEpisodeNumber").arg(episode.number)

    onClicked: if (!upcoming) chosen()
    onActiveFocusChanged: if (activeFocus && !upcoming) chosen()
    Keys.onLeftPressed: step(-1)
    Keys.onRightPressed: step(1)
    Keys.onReturnPressed: if (!upcoming) played()
    Keys.onEnterPressed: if (!upcoming) played()
    HoverHandler { cursorShape: card.upcoming ? Qt.ArrowCursor : Qt.PointingHandCursor }

    background: null
    contentItem: Column {
        spacing: 0

        EpisodeStill {
            id: still
            width: card.width
            height: card.width * 9 / 16
            episode: card.episode
            stills: card.stills
            watched: card.watched
            bar: card.bar
            faint: card.upcoming || card.unreachable

            DownloadMark {
                anchors { top: parent.top; right: parent.right; margins: 8 }
                visible: card.mark !== undefined
                mark: card.mark ?? {}
            }

            // The mouse's way to start; the keyboard has Enter.
            AbstractButton {
                anchors.centerIn: parent
                width: 56
                height: 56
                visible: card.hovered && !card.upcoming
                focusPolicy: Qt.NoFocus
                ToolTip.text: qsTrId("itemPlayEpisode").arg(card.episode.number)
                ToolTip.visible: hovered
                ToolTip.delay: 500
                onClicked: card.played()

                background: Rectangle { radius: width / 2; color: "#ebffffff" }
                contentItem: Item {
                    Glyph { anchors.centerIn: parent; glyph: "play_arrow"; size: 30; color: "black" }
                }
            }

            // Outside the picture, so it reads at a glance over any still. A
            // card the keyboard is on but cannot choose is marked apart.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: Tokens.radiusArt + 2
                color: "transparent"
                visible: card.selected || card.activeFocus
                border.width: 2
                border.color: card.selected || !card.upcoming ? Tokens.text : Tokens.muted
            }
        }

        Item { width: 1; height: 10 }
        Text {
            width: card.width
            text: card.named ? qsTrId("itemEpisodeCardNamed").arg(card.episode.number).arg(card.named)
                             : qsTrId("itemEpisodeNumber").arg(card.episode.number)
            color: card.upcoming || card.unreachable ? Tokens.muted
                 : card.selected || card.activeFocus ? Tokens.text : Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: 15
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Item { width: 1; height: 4 }
        Text {
            width: card.width
            text: {
                const parts = []
                const released = card.episode.released
                if (released && card.upcoming)
                    parts.push(qsTrId("itemOutDate").arg(Words.shortDate(released)))
                // Only lately out, or not out yet, is the air date worth showing.
                else if (released && (new Date() - new Date(released)) / 86400000 <= 14)
                    parts.push(Words.shortDate(released))
                if (card.episode.rating > 0)
                    parts.push(Format.rating(card.episode.rating, Qt.locale()))
                return parts.join(" · ")
            }
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            elide: Text.ElideRight
        }
    }
}
