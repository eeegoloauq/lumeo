import QtQuick
import QtQuick.Controls
import Lumeo

// What the player shows before the picture: the wait for the film, then the
// reason it did not start.
Item {
    id: waiting

    required property Playback playback

    readonly property bool failed: playback.failure !== Playback.None
    readonly property var download: playback.download
    readonly property bool active: download.state === "active"

    // The title and the ring only once the wait is long enough to need
    // saying: a file on disk opens in under a second, and a ring flashed for
    // half of it read as something going wrong.
    property bool patient: false
    Timer { interval: 1000; running: true; onTriggered: waiting.patient = true }

    // Counts the time spent finding peers between polls.
    property date now: new Date()
    Timer {
        interval: 1000
        repeat: true
        running: waiting.active && !!waiting.download.waitingSince
        onTriggered: waiting.now = new Date()
    }

    // What the wait is on: how long it has looked for peers, then how many it
    // found, then how much has come and how fast.
    function waitLine() {
        const progress = download.progress ?? {}
        const peers = progress.peers ?? 0
        switch (playback.stage) {
        case "findingPeers": {
            const label = download.offline ? qsTrId("downloadsOffline") : qsTrId("downloadsFindingPeers")
            if (!download.waitingSince)
                return label
            return qsTrId("downloadsWaitingSince").arg(label)
                .arg(Words.clock((now - new Date(download.waitingSince)) / 1000))
        }
        case "fetchingMetadata":
            return qsTrId("playerPeers", peers).arg(qsTrId("downloadsFetchingMetadata"))
        default: {
            const total = progress.total ?? 0
            const percent = total > 0 ? Math.round(100 * (progress.completed ?? 0) / total) : 0
            const line = [qsTrId("playerPeers", peers).arg(qsTrId("playerPercent").arg(percent))]
            if ((progress.rate ?? 0) > 0)
                line.push(qsTrId("downloadsRate").arg(Words.bytes(progress.rate)))
            return line.join(" · ")
        }
        }
    }

    function message() {
        if (playback.failure === Playback.CoreStopped)
            return qsTrId("playerCoreStopped")
        return qsTrId("playerCopyWouldNotStart")
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(600, parent.width - 48)
        spacing: 8
        visible: waiting.failed || waiting.patient

        BusyIndicator {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 56
            height: 56
            visible: !waiting.failed
            running: visible
            palette.dark: "white"
        }

        Item { width: 1; height: 16; visible: !waiting.failed }

        Text {
            objectName: "waitingTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: waiting.playback.title
            maximumLineCount: 2
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 20
            font.weight: Font.DemiBold
        }

        Text {
            objectName: "waitLine"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !waiting.failed && waiting.active
            text: waiting.active ? waiting.waitLine() : ""
            color: "#99ffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 13
            font.features: { "tnum": 1 }
        }

        Text {
            objectName: "failure"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: waiting.failed
            text: waiting.failed ? waiting.message() : ""
            color: "#aaaaaa"
            font.family: Tokens.fontSans
            font.pixelSize: 13
        }

        Item { width: 1; height: 8; visible: waiting.failed }

        QuietButton {
            objectName: "tryAgain"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: waiting.failed
            text: qsTrId("playerTryAgain")
            onClicked: waiting.playback.retry()
        }
    }
}
