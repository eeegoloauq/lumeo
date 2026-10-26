pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// The title's episodes over the picture: a season at a time, the one playing
// lit, how much of each was watched, and any released one a press away.
MenuPanel {
    id: panel

    required property Playback playback
    property real room: 600

    signal play(var episode)

    readonly property int playingSeason: playback.download.season ?? 0
    readonly property int playingNumber: playback.download.episode ?? 0
    property int season: playingSeason
    readonly property var seasons: [...new Set(playback.episodes.map(e => e.season))].sort((a, b) => a - b)
    readonly property var episodes: playback.episodes.filter(e => e.season === season)

    function entry(e) {
        return (playback.watching.entries ?? []).find(w => w.season === e.season && w.episode === e.number)
    }

    function detail(e) {
        if (e.released && new Date(e.released) > new Date())
            return qsTrId("playerOutDate").arg(Words.shortDate(e.released))
        const w = entry(e)
        if (w && w.position > 0 && w.duration > w.position)
            return qsTrId("downloadsTimeLeftMinutes", Math.floor((w.duration - w.position) / 60))
        const minutes = Math.floor((w?.duration ?? 0) / 60)
        return [minutes > 0 ? qsTrId("downloadsMinutes", minutes) : playback.runtime,
                w?.watched ? qsTrId("playerWatched") : ""].filter(p => p).join(" · ")
    }

    width: 440
    implicitHeight: seasonRow.height + list.height + 16
    height: Math.min(implicitHeight, room)

    onVisibleChanged: if (visible) {
        season = playingSeason
        playback.loadProgress()
        // The playing episode second from the top, so the one before shows too.
        const at = episodes.findIndex(e => e.number === playingNumber)
        list.positionViewAtIndex(Math.max(0, at - 1), ListView.Beginning)
    }

    Item {
        id: seasonRow
        width: panel.width
        height: 44

        Button {
            id: seasonButton
            objectName: "seasonButton"
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            flat: true
            focusPolicy: Qt.NoFocus
            text: qsTrId("playerSeasonDropdown").arg(panel.season)
            font.family: Tokens.fontSans
            font.pixelSize: 15
            font.weight: Font.DemiBold
            palette.buttonText: "white"
            onClicked: seasonMenu.open()

            Menu {
                id: seasonMenu
                y: seasonButton.height
                Repeater {
                    model: panel.seasons
                    delegate: MenuItem {
                        required property int modelData
                        objectName: "season-" + modelData
                        text: qsTrId("playerSeason").arg(modelData)
                        onTriggered: panel.season = modelData
                    }
                }
            }
        }
    }

    ListView {
        id: list
        width: panel.width
        height: Math.min(contentHeight, panel.room - seasonRow.height - 16)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: panel.episodes
        delegate: ItemDelegate {
            id: row
            required property var modelData
            readonly property bool current: modelData.season === panel.playingSeason
                                            && modelData.number === panel.playingNumber
            readonly property bool upcoming: !!modelData.released && new Date(modelData.released) > new Date()
            readonly property var watched: panel.entry(modelData)

            objectName: "episode-" + modelData.season + "-" + modelData.number
            width: list.width
            height: 88
            focusPolicy: Qt.NoFocus
            opacity: upcoming ? 0.45 : 1
            enabled: !upcoming && !current
            padding: 8
            leftPadding: 16
            rightPadding: 16
            background: Rectangle { color: row.current || row.hovered ? "#14ffffff" : "transparent" }
            onClicked: panel.play(modelData)

            contentItem: Row {
                spacing: 12

                EpisodeStill {
                    width: 128
                    height: 72
                    episode: row.modelData
                    stills: Preferences.current.episodeArtwork ?? "show"
                    frame: EpisodeFrames.known[panel.playback.download.itemId + "/" + row.modelData.season
                                               + "/" + row.modelData.number] ?? ""
                    watched: row.watched?.watched ?? false
                    bar: !row.watched ? 0 : row.watched.position > 0 ? row.watched.position / row.watched.duration
                                                                      : row.watched.watched ? 1 : 0
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: row.availableWidth - 140
                    spacing: 4

                    Text {
                        width: parent.width
                        text: Words.episodeName(row.modelData)
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        color: "white"
                        font.family: Tokens.fontSans
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: panel.detail(row.modelData)
                        color: "#aaaaaa"
                        font.family: Tokens.fontSans
                        font.pixelSize: 13
                    }
                }
            }
        }
    }
}
