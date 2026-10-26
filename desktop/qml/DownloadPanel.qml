pragma ComponentBehavior: Bound

import QtQuick
import Lumeo

// Behind the download button: how this file is arriving and, in a series,
// what the prefetch is doing with the next one.
MenuPanel {
    id: panel

    required property Playback playback
    // The copy playing as the Source page names it; empty until the list
    // is here.
    property string source

    signal openSource()
    signal storage()

    readonly property var download: playback.download
    readonly property Next next: playback.next
    readonly property var episode: next?.episode ?? ({})
    readonly property var nextDownload: next?.download ?? ({})

    width: 340
    implicitHeight: lines.height + 16
    height: implicitHeight

    Column {
        id: lines
        width: panel.width

        Caption { text: (panel.download.episode ?? 0) > 0 ? qsTrId("playerThisEpisode") : qsTrId("playerThisFilm") }
        DownloadState { download: panel.download }

        MenuRow {
            objectName: "downloadSource"
            visible: !!panel.download.itemId
            width: parent.width
            check: false
            opens: true
            label: panel.source || (panel.download.name ?? "")
            detail: qsTrId("playerSource")
            onClicked: panel.openSource()
        }

        Column {
            visible: !!panel.episode.number
            width: parent.width

            Rectangle { width: parent.width; height: 17; color: "transparent"
                Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: "#1fffffff" } }
            Caption {
                text: qsTrId("playerNextNamed").arg([qsTrId("downloadsEpisode").arg(panel.episode.number ?? 0),
                    panel.episode.title && panel.episode.title !== "Episode " + panel.episode.number ? panel.episode.title : ""]
                    .filter(p => p).join(" "))
            }

            DownloadState { visible: !!panel.nextDownload.id; download: panel.nextDownload }

            // Why there is no download of it yet, and the way to one.
            Column {
                visible: !panel.nextDownload.id || panel.nextDownload.state === "failed"
                width: parent.width

                readonly property int fetch: !panel.next ? Next.Waiting
                    : panel.next.fetch === Next.Waiting && Preferences.current.prefetch === false ? Next.Off
                    : panel.next.fetch

                Line {
                    visible: !panel.nextDownload.id && parent.fetch !== Next.Off
                    text: [qsTrId("playerWaiting"), qsTrId("playerWaiting"), qsTrId("playerNoRoom"),
                           qsTrId("playerNoCopiesShort"), qsTrId("playerFailed")][parent.fetch]
                }
                FetchAction {
                    objectName: "downloadNext"
                    visible: !!panel.nextDownload.id || parent.fetch !== Next.NoCopy
                    label: parent.fetch === Next.NoRoom && !panel.nextDownload.id ? qsTrId("playerDownloadAnyway")
                                                                                 : qsTrId("playerDownloadNow")
                    onClicked: panel.next.downloadNow()
                }
                FetchAction {
                    visible: parent.fetch === Next.NoRoom && !panel.nextDownload.id
                    label: qsTrId("playerStorageSettings")
                    onClicked: panel.storage()
                }
            }
        }
    }

    component Caption: Text {
        width: parent.width
        leftPadding: 12
        rightPadding: 12
        topPadding: 10
        bottomPadding: 2
        elide: Text.ElideRight
        color: "#aaaaaa"
        font.family: Tokens.fontSans
        font.pixelSize: 12
    }

    component Line: Item {
        id: line
        property string text
        property string value
        property bool done
        width: parent.width
        implicitHeight: 24

        Rectangle {
            id: dot
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            visible: line.done
            width: 10
            height: 10
            radius: 5
            color: "white"
        }
        Text {
            anchors { left: line.done ? dot.right : parent.left; leftMargin: line.done ? 8 : 12; verticalCenter: parent.verticalCenter }
            text: line.text
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 14
        }
        Text {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            text: line.value
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 14
            font.features: { "tnum": 1 }
        }
    }

    component Note: Text {
        width: parent.width
        visible: text !== ""
        leftPadding: 12
        rightPadding: 12
        bottomPadding: 2
        color: "#aaaaaa"
        font.family: Tokens.fontSans
        font.pixelSize: 12
        font.features: { "tnum": 1 }
    }

    component FetchAction: MenuRow {
        id: action
        width: parent.width
        check: false
        label: ""

        Glyph { glyph: "download"; color: "#ccffffff" }
    }

    // A download's state: on disk, arriving and how fast, failed or paused.
    component DownloadState: Column {
        id: shown
        required property var download
        readonly property var progress: download.progress ?? {}
        readonly property real fraction: progress.total > 0 ? Math.min(1, progress.completed / progress.total) : 0
        width: parent.width

        Line {
            visible: shown.download.state === "done"
            text: qsTrId("playerOnDisk")
            value: Words.bytes(shown.progress.total ?? 0)
            done: true
        }
        Note {
            text: shown.download.state === "done" && shown.download.seeding && shown.progress.upload > 0
                  ? qsTrId("playerPeers", shown.progress.peers ?? 0)
                        .arg(qsTrId("downloadsUploadArrow").arg(Words.bytes(shown.progress.upload))) : ""
        }

        Line {
            visible: shown.download.state === "active"
            text: qsTrId("playerDownloading")
            value: qsTrId("playerPercent").arg(Math.round(shown.fraction * 100))
        }
        Item {
            visible: shown.download.state === "active"
            width: parent.width
            height: 18
            Rectangle {
                anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12; verticalCenter: parent.verticalCenter }
                height: 4
                radius: 2
                color: "#2effffff"
                Rectangle { width: parent.width * shown.fraction; height: parent.height; radius: 2; color: Theme.accent }
            }
        }
        Note {
            text: shown.download.state !== "active" ? ""
                : [shown.progress.total > 0 ? qsTrId("playerDownloadProgress").arg(Words.bytes(shown.progress.completed ?? 0))
                                                   .arg(Words.bytes(shown.progress.total)) : "",
                   shown.progress.eta > 0 ? qsTrId("downloadsAboutDuration").arg(Words.timeLeft(shown.progress.eta)) : ""]
                  .filter(p => p).join(" · ")
        }
        Note {
            readonly property int peers: shown.progress.peers ?? 0
            text: shown.download.state !== "active" ? ""
                : peers === 0 ? qsTrId("downloadsFindingPeers")
                : !shown.download.resolved ? qsTrId("playerPeers", peers).arg(qsTrId("downloadsFetchingMetadata"))
                : qsTrId("playerPeersSeeding", peers)
                      .arg([qsTrId("downloadsRateArrow").arg(Words.bytes(shown.progress.rate ?? 0)),
                            shown.progress.upload > 0 ? qsTrId("downloadsUploadArrow").arg(Words.bytes(shown.progress.upload)) : ""]
                           .filter(p => p).join(" · "))
                      .arg(qsTrId("playerPeersSeeding_seeders", shown.progress.seeders ?? 0))
        }

        Line {
            visible: shown.download.state === "failed"
            text: qsTrId("playerFailed")
        }
        Line {
            visible: shown.download.state === "paused"
            text: qsTrId("playerPaused")
        }
    }
}
