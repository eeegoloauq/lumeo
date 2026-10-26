pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Qt.labs.qmlmodels
import Lumeo
import "format.js" as Format

// What the bar's ring opens: downloads by what can be done with them, and
// the disk they take (decisions/interface.md).
Popup {
    id: panel

    required property DownloadList list
    // The window's height, which a long list is held to.
    property real ceiling: 800

    signal watch(string downloadId, string name)
    signal openTitle(var item)
    signal storage()

    // "Finding peers · 4 min" counts while no poll changes anything.
    property double now: Date.now()

    width: 400
    padding: 0
    topPadding: 0
    bottomPadding: 0

    onAboutToShow: {
        now = Date.now()
        list.refresh()
        disk.load()
    }

    Timer { interval: 30000; repeat: true; running: panel.opened; onTriggered: panel.now = Date.now() }

    Storage { id: disk }

    background: Rectangle {
        radius: Tokens.radiusFloating
        color: Qt.alpha(Tokens.floating, 0.97)
        border.color: Tokens.rim
    }

    // "S1 E9–E10, S2 E1–E3" from {season, first, last} runs.
    function episodes(runs) {
        const seasons = []
        for (const run of runs ?? []) {
            const words = run.first === run.last ? qsTrId("downloadsEpisode").arg(run.first)
                                                 : qsTrId("downloadsEpisodeRange").arg(run.first).arg(run.last)
            const last = seasons[seasons.length - 1]
            if (last && last.season === run.season)
                last.words.push(words)
            else
                seasons.push({ season: run.season, words: [words] })
        }
        return seasons.map(s => qsTrId("downloadsSeasonRun").arg(s.season).arg(s.words.join(", "))).join(", ")
    }

    function episode(season, number) {
        return qsTrId("downloadsSeasonRun").arg(season).arg(qsTrId("downloadsEpisode").arg(number))
    }

    function percent(row) {
        return qsTrId("downloadsPercent").arg(Math.floor(row.fraction * 100))
    }

    // What a waiting row waits on, and for how long once it is a minute.
    function waiting(row) {
        if (row.kind === DownloadList.Paused)
            return qsTrId("downloadsPaused")
        if (row.kind === DownloadList.Failed)
            return row.error || qsTrId("downloadsFailed")
        const what = row.offline ? qsTrId("downloadsOffline")
                   : row.peers === 0 ? qsTrId("downloadsFindingPeers")
                   : !row.resolved ? qsTrId("downloadsFetchingMetadata")
                   : qsTrId("downloadsPeersNotSending")
        const waited = row.waitingSince ? Math.floor((now - Date.parse(row.waitingSince)) / 60000) : 0
        return waited >= 1 ? qsTrId("downloadsWaitingSince").arg(what).arg(Words.minutes(waited * 60)) : what
    }

    // The line under a title: its size, how it arrives, or what it waits on.
    function line(row) {
        switch (row.kind) {
        case DownloadList.Ready:
            return [row.opens ? qsTrId("downloadsEpisodeNext").arg(episode(row.season, row.episode)) : "",
                    Words.bytes(row.size)].filter(p => p).join(" · ")
        case DownloadList.Arriving:
            return [percent(row), row.rate > 0 ? qsTrId("downloadsRate").arg(Words.bytes(row.rate)) : "",
                    row.eta > 0 ? Words.timeLeft(row.eta) : ""].filter(p => p).join(" · ")
        default:
            // How much is here stays in sight: it says whether waiting is worth it.
            return [row.size > 0 ? percent(row) : "", waiting(row)].filter(p => p).join(" · ")
        }
    }

    // A row plays what it has, opens into its episodes, or goes to its title.
    function pick(row) {
        if (row.type === "row" && row.opens) {
            list.toggle(row.key)
            return
        }
        if (row.play?.id) {
            play(row)
            return
        }
        if (row.itemId) {
            close()
            const item = Downloads.itemOf(row.itemId)
            openTitle(item.id ? item : { id: row.itemId })
        }
    }

    function play(row) {
        close()
        watch(row.play.id, row.play.episode > 0
              ? qsTrId("itemPlaybackTitle").arg(row.title).arg(Words.padded(row.play.season)).arg(Words.padded(row.play.episode))
              : row.title)
    }

    contentItem: Column {
        Item {
            width: panel.width
            height: 40

            Text {
                anchors { left: parent.left; leftMargin: 16; baseline: parent.bottom; baselineOffset: -8 }
                text: qsTrId("settingsDownloads")
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Small {
                anchors { right: parent.right; rightMargin: 16; baseline: parent.bottom; baselineOffset: -8 }
                text: [panel.list.rate > 0 ? qsTrId("downloadsRateArrow").arg(Words.bytes(panel.list.rate)) : "",
                       panel.list.upload > 0 ? qsTrId("downloadsUploadArrow").arg(Words.bytes(panel.list.upload)) : ""]
                      .filter(p => p).join("   ")
            }
        }

        Small {
            objectName: "downloadsNothing"
            visible: rows.count === 0
            leftPadding: 16
            topPadding: 18
            bottomPadding: 22
            text: qsTrId("downloadsNothing")
            font.pixelSize: Tokens.textData
        }

        ListView {
            id: rows
            objectName: "downloadRows"
            width: panel.width
            // A season is many rows: without a ceiling the last are off screen.
            height: Math.min(contentHeight, panel.ceiling * 0.6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: panel.list.rows
            delegate: DelegateChooser {
                role: "type"
                DelegateChoice { roleValue: "section"; Section {} }
                DelegateChoice { roleValue: "row"; TitleRow {} }
                DelegateChoice { roleValue: "episode"; EpisodeRow {} }
            }
        }

        Item { width: 1; height: 8 }
        Rectangle { width: panel.width; height: 1; color: Tokens.divider }

        Column {
            width: panel.width
            padding: 16
            topPadding: 12
            bottomPadding: 6
            spacing: 4

            DiskBar {
                width: parent.width - 32
                height: 4
                storage: disk
                visible: disk.diskTotal > 0
            }
            Item {
                width: parent.width - 32
                height: 28

                Small {
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property real limit: Preferences.current.diskLimit ?? 0
                    text: !disk.known ? ""
                        : limit > 0 ? qsTrId("downloadsUsedOf").arg(Words.bytes(disk.used)).arg(Words.bytes(limit))
                        : disk.diskFree > 0 ? qsTrId("downloadsUsedFree").arg(Words.bytes(disk.used)).arg(Words.bytes(disk.diskFree))
                        : qsTrId("downloadsUsedOnDisk").arg(Words.bytes(disk.used))
                }
                Link {
                    objectName: "downloadsStorage"
                    anchors { right: parent.right; rightMargin: -8; verticalCenter: parent.verticalCenter }
                    text: qsTrId("downloadsStorageLink")
                    onClicked: {
                        panel.close()
                        panel.storage()
                    }
                }
            }
        }
    }

    component Small: Text {
        color: Tokens.muted
        font.family: Tokens.fontSans
        font.pixelSize: 12
        font.features: { "tnum": 1 }
    }

    component Link: ToolButton {
        id: link
        implicitHeight: 26
        leftPadding: 8
        rightPadding: 8
        focusPolicy: Qt.TabFocus
        font.family: Tokens.fontSans
        font.pixelSize: 12
        palette.buttonText: link.hovered ? Tokens.text : Tokens.dim
        background: Rectangle {
            radius: Tokens.radiusControl
            color: link.down || link.hovered ? Tokens.hover : "transparent"
            border.width: link.visualFocus ? 2 : 0
            border.color: Theme.accent
        }
    }

    component Action: IconButton {
        tone: Tokens.muted
        implicitWidth: 32
        implicitHeight: 32
    }

    // What will play is marked in the accent, as everywhere else.
    component PlayAction: ToolButton {
        id: play
        property string tip
        implicitWidth: 32
        implicitHeight: 32
        padding: 0
        focusPolicy: Qt.TabFocus
        display: AbstractButton.IconOnly
        icon.source: "qrc:/qt/qml/Lumeo/icons/play_arrow.svg"
        icon.width: 20
        icon.height: 20
        icon.color: Tokens.page
        Accessible.name: tip
        ToolTip.text: tip
        ToolTip.visible: hovered
        ToolTip.delay: 500
        background: Rectangle {
            radius: height / 2
            color: play.down ? Qt.darker(Theme.accent, 1.15) : Theme.accent
            border.width: play.visualFocus ? 2 : 0
            border.color: Tokens.text
        }
    }

    component Section: Item {
        id: section
        required property string key
        required property string section
        required property int count
        required property double eta

        width: ListView.view.width
        height: 44
        objectName: key

        Rectangle {
            visible: section.section !== "ready"
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 2 }
            height: 1
            color: Tokens.divider
        }
        Row {
            anchors { left: parent.left; leftMargin: 16; bottom: parent.bottom; bottomMargin: 8 }
            spacing: 8
            Small {
                text: ({ ready: qsTrId("downloadsReadyToWatch"), arriving: qsTrId("downloadsArriving"),
                         waiting: qsTrId("downloadsWaiting") })[section.section].toUpperCase()
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.9
            }
            Small {
                objectName: "count"
                text: Words.count(section.count)
                opacity: 0.7
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }
        Small {
            anchors { right: parent.right; rightMargin: 16; bottom: parent.bottom; bottomMargin: 8 }
            visible: section.eta > 0
            text: qsTrId("downloadsAboutDuration").arg(Words.minutes(section.eta))
        }
        Link {
            objectName: "downloadsClear"
            visible: section.section === "ready"
            anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 3 }
            text: qsTrId("commonClear")
            onClicked: panel.list.clear()
        }
    }

    // A row of the list with what it knows (DownloadList's roles); it plays
    // what it has, opens, or goes to its title when clicked.
    component Entry: AbstractButton {
        id: entry
        required property string type
        required property string key
        required property string section
        required property int kind
        required property var ids
        required property string itemId
        required property string title
        required property string poster
        required property var runs
        required property string tag
        required property double size
        required property double fraction
        required property double rate
        required property double eta
        required property string waitingSince
        required property int peers
        required property bool resolved
        required property bool offline
        required property string error
        required property bool opens
        required property bool expanded
        required property var play
        required property int season
        required property int episode

        objectName: "download-" + key
        width: ListView.view.width
        focusPolicy: Qt.TabFocus
        onClicked: panel.pick(entry)

        background: Rectangle { color: entry.hovered || entry.visualFocus ? Tokens.hover : "transparent" }
    }

    // A film, or a series' episodes in one state, which it opens into.
    component TitleRow: Entry {
        id: entry
        readonly property bool waits: section === "waiting"
        readonly property string label: runs.length ? panel.episodes(runs) : tag

        height: 64
        Accessible.name: title

        contentItem: Item {
            Rectangle {
                id: art
                x: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 32
                height: 48
                radius: Tokens.radiusArt
                color: Tokens.raised
                opacity: entry.waits ? 0.6 : 1
                clip: true
                Image {
                    anchors.fill: parent
                    source: Format.art(entry.poster)
                    sourceSize.width: 64
                    fillMode: Image.PreserveAspectCrop
                }
            }
            Column {
                anchors { left: art.right; leftMargin: 12; right: actions.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 4

                Row {
                    width: parent.width
                    spacing: 8
                    Text {
                        id: name
                        width: Math.min(implicitWidth, parent.width - tagText.width - chevron.width - 16)
                        text: entry.title
                        elide: Text.ElideRight
                        color: entry.waits ? Tokens.dim : Tokens.text
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textCard
                        font.weight: Font.DemiBold
                    }
                    Small {
                        id: tagText
                        objectName: "tag"
                        anchors.baseline: name.baseline
                        text: entry.label
                    }
                    Glyph {
                        id: chevron
                        anchors.verticalCenter: parent.verticalCenter
                        visible: entry.opens
                        width: visible ? 16 : 0
                        glyph: "expand_more"
                        size: 16
                        color: Tokens.muted
                        rotation: entry.expanded ? 180 : 0
                    }
                }
                Rectangle {
                    visible: entry.kind === DownloadList.Arriving || entry.waits && entry.size > 0
                    width: parent.width
                    height: 3
                    radius: 2
                    color: Qt.alpha(Tokens.text, 0.14)
                    Rectangle {
                        width: parent.width * entry.fraction
                        height: parent.height
                        radius: 2
                        color: entry.waits ? Tokens.dim : Theme.accent
                    }
                }
                Small {
                    objectName: "line"
                    width: parent.width
                    text: panel.line(entry)
                    elide: Text.ElideRight
                    color: entry.kind === DownloadList.Failed ? Tokens.warn : Tokens.muted
                }
            }
            Actions {
                id: actions
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                target: entry
                which: entry.opens ? entry.label : ""
            }
        }
    }

    // One episode of a row opened out under it.
    component EpisodeRow: Entry {
        id: entry
        height: 32

        contentItem: Item {
            Text {
                x: 60
                anchors.verticalCenter: parent.verticalCenter
                text: panel.episode(entry.season, entry.episode)
                color: entry.section === "waiting" ? Tokens.muted : Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
            }
            Small {
                anchors { right: actions.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                text: entry.kind === DownloadList.Ready ? Words.bytes(entry.size)
                    : entry.kind === DownloadList.Arriving ? panel.percent(entry)
                    : [entry.size > 0 ? panel.percent(entry) : "", panel.waiting(entry)].filter(p => p).join(" · ")
            }
            Actions {
                id: actions
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                // Play is the row itself here.
                visible: entry.kind !== DownloadList.Ready
                width: visible ? implicitWidth : 0
                target: entry
                small: true
            }
        }
    }

    // The one thing a row's state lets you do, and Stop for what waits: a
    // download with bytes flowing is paused first, so one that goes well is
    // never thrown away by a click beside Pause.
    component Actions: Row {
        id: actions
        required property var target
        property string which
        property bool small

        spacing: 0

        PlayAction {
            objectName: "play"
            visible: actions.target.kind === DownloadList.Ready
            tip: actions.target.episode > 0 ? qsTrId("playerPlayEpisode").arg(actions.target.season).arg(actions.target.episode)
                                         : qsTrId("commonPlay")
            onClicked: panel.play(actions.target)
        }
        Action {
            objectName: "pause"
            visible: actions.target.kind === DownloadList.Arriving
            glyph: "pause"
            glyphSize: actions.small ? 16 : 18
            tip: actions.which ? qsTrId("downloadsPause").arg(actions.which) : qsTrId("downloadsPauseOne")
            onClicked: actions.target.ids.forEach(id => Downloads.pause(id))
        }
        Action {
            objectName: "resume"
            visible: actions.target.kind === DownloadList.Paused || actions.target.kind === DownloadList.Failed
            glyph: actions.target.kind === DownloadList.Paused ? "play_arrow" : "refresh"
            glyphSize: actions.small ? 16 : 18
            tip: actions.target.kind === DownloadList.Paused
                 ? (actions.which ? qsTrId("downloadsResume").arg(actions.which) : qsTrId("downloadsResumeOne"))
                 : (actions.which ? qsTrId("downloadsRetry").arg(actions.which) : qsTrId("downloadsRetryOne"))
            onClicked: actions.target.ids.forEach(id => Downloads.resume(id))
        }
        Action {
            objectName: "stop"
            visible: actions.target.section === "waiting"
            glyph: "close"
            glyphSize: actions.small ? 16 : 18
            tip: actions.which ? qsTrId("downloadsStopDiscard").arg(actions.which) : qsTrId("downloadsStopDiscardOne")
            onClicked: actions.target.ids.forEach(id => Downloads.stop(id))
        }
    }
}
