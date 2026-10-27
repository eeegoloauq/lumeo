import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// What the player shows before the picture: the wait for the film, then the
// reason it did not start.
Item {
    id: waiting

    required property Playback playback
    // The title's copies, for another to offer and for a switch to one.
    required property SourceChoice copies
    // Another copy was picked and is starting: the wait is for it.
    property bool switching: false
    // Over the picture, which goes dark rather than away.
    property bool overPicture: false
    // What is waited for: another episode's name while one starts.
    property string title: playback.title

    signal pickCopy(int index)
    signal retrySwitch()

    readonly property bool switchFailed: switching && !!copies
                                         && (copies.errorStatus >= 0 || (copies.listed && copies.sources.length === 0))
    readonly property bool failed: switchFailed || (!switching && playback.failure !== Playback.None)
    readonly property int nextCopy: playback.findingNoPeers && copies ? playback.nextCopy(copies.sources) : -1
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
        if (switching)
            return copies.errorStatus >= 0 ? qsTrId("playerCouldNotStartCopy")
                                           : qsTrId("playerNoCopyOf").arg(title)
        if (playback.url !== "")
            return qsTrId("playerTrailerFailed")
        if (playback.failure === Playback.CoreStopped)
            return qsTrId("playerCoreStopped")
        if (playback.codec && MpvFacts.has(playback.codec) === 0)
            return qsTrId("playerDecoderMissingShort").arg(playback.codec)
        return qsTrId("playerCopyWouldNotStart")
    }

    Rectangle {
        anchors.fill: parent
        visible: waiting.overPicture
        color: "#99000000"
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
            text: waiting.title
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
            visible: !waiting.failed && !waiting.switching && waiting.active
            text: waiting.active ? waiting.waitLine() : ""
            color: "#99ffffff"
            font.family: Tokens.fontSans
            font.pixelSize: 13
            font.features: { "tnum": 1 }
        }

        // Below the line, so the ring and the title stay put.
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !waiting.failed && !waiting.switching && waiting.nextCopy >= 0
            topPadding: 8
            spacing: 8

            QuietButton {
                objectName: "anotherCopy"
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTrId("playerTryAnotherCopy")
                onClicked: waiting.pickCopy(waiting.nextCopy)
            }

            Text {
                readonly property var copy: waiting.copies.sources[waiting.nextCopy] ?? ({})
                anchors.horizontalCenter: parent.horizontalCenter
                text: [[copy.release?.resolution ?? "", Words.sourceTitle(copy)].filter(p => p).join(" · "),
                       copy.size > 0 ? Words.bytes(copy.size) : "",
                       copy.seeders > 0 ? qsTrId("playerSeedCount", copy.seeders) : ""].filter(p => p).join(" · ")
                color: "#80ffffff"
                font.family: Tokens.fontSans
                font.pixelSize: 12
            }
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

        // How to install what is missing, to copy into a terminal.
        TextEdit {
            objectName: "installHint"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: waiting.failed && !waiting.switching && !!waiting.playback.codec
                     && MpvFacts.has(waiting.playback.codec) === 0 && MpvFacts.installHint !== ""
            width: Math.min(implicitWidth, parent.width)
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            horizontalAlignment: TextEdit.AlignHCenter
            text: MpvFacts.installHint
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
        }

        Item { width: 1; height: 8; visible: waiting.failed }

        QuietButton {
            objectName: "tryAgain"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: waiting.failed
            text: qsTrId("playerTryAgain")
            onClicked: waiting.switching ? waiting.retrySwitch() : waiting.playback.retry()
        }
    }
}
