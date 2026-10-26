pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// The gear: what is about neither which film it is nor its language. The
// copy, speed and picture, the chapters to jump by, the decoder, and mpv's
// statistics. Every value is read back from mpv (decisions/player.md).
MenuPanel {
    id: menu

    required property MpvItem mpv
    required property Playback playback
    required property SourceChoice copies
    // How tall it may grow: the window less the bar.
    property real room: 600
    // The page on show; "" for the list of them.
    property string page: ""

    // A pick that leaves nothing more to do here: the menu goes.
    signal done()
    // Audio and subtitles were asked for: their menu takes this one's place.
    signal tracks()
    signal pickCopy(int index)

    readonly property var rates: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    readonly property var fits: [qsTrId("playerFit"), qsTrId("playerFill"), qsTrId("playerStretch")]
    readonly property int playing: playback.playingCopy(copies.sources)

    function rate(value) {
        return value === 1 ? qsTrId("playerSpeedNormal")
            : qsTrId("playerRate").arg(Number(value).toLocaleString(Qt.locale(), "f", 2).replace(/[.,]?0+$/, ""))
    }

    function copyLabel(s) {
        return [s.release?.resolution ?? "", Words.sourceTitle(s)].filter(p => p).join(" · ")
    }

    function copyNote(s) {
        const codes = (s.languages ?? []).map(l => l.toUpperCase())
        const languages = codes.length <= 3 ? codes
            : codes.slice(0, 3).concat([qsTrId("downloadsMoreLanguages", codes.length - 3)])
        return [s.local === "done" ? qsTrId("downloadsOnDiskLower") : s.local === "partial" ? qsTrId("downloadsPartOnDisk") : "",
                languages.join(" "), s.lastUsed ? qsTrId("playerLastUsed") : ""].filter(p => p).join(" · ")
    }

    function chapterLabel(index) {
        return mpv.chapters[index].title || qsTrId("playerChapter").arg(index + 1)
    }

    readonly property var titles: ({
        source: qsTrId("playerSource"),
        speed: qsTrId("playerSpeed"),
        picture: qsTrId("playerPicture"),
        chapters: qsTrId("playerChapters"),
        decoding: qsTrId("playerDecoding"),
    })

    width: page === "speed" ? 240 : page === "source" ? 340 : 280
    implicitHeight: shown.height + 16
    height: Math.min(implicitHeight, room)

    Column {
        id: shown
        width: menu.width

        // A page's title, which goes back to the list.
        ItemDelegate {
            id: back
            objectName: "menuBack"
            visible: menu.page !== ""
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
                    text: menu.titles[menu.page] ?? ""
                    color: "white"
                    font.family: Tokens.fontSans
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }
            }
            onClicked: menu.page = ""
        }

        Rectangle { visible: menu.page !== ""; width: parent.width; height: 1; color: "#1fffffff" }

        Flickable {
            width: parent.width
            height: Math.min(rows.height, menu.room - 16 - (menu.page !== "" ? 45 : 0))
            contentHeight: rows.height
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Column {
                id: rows
                width: parent.width

                // The list of pages.
                Column {
                    visible: menu.page === ""
                    width: parent.width

                    MenuRow {
                        width: parent.width
                        check: false
                        label: qsTrId("playerShortcutTracks")
                        detail: "C"
                        onClicked: menu.tracks()
                    }
                    PageRow { shows: "source"; value: menu.playing >= 0 ? menu.copyLabel(menu.copies.sources[menu.playing]) : "" }
                    PageRow { shows: "speed"; value: menu.rate(menu.mpv.speed) }
                    PageRow { shows: "picture"; value: menu.fits[menu.mpv.fit] }
                    PageRow {
                        shows: "chapters"
                        visible: menu.mpv.chapters.length > 0
                        value: menu.mpv.chapter >= 0 && menu.mpv.chapter < menu.mpv.chapters.length
                               ? menu.chapterLabel(menu.mpv.chapter) : ""
                    }
                    PageRow {
                        shows: "decoding"
                        value: menu.mpv.hwdec === "no" ? qsTrId("playerSoftware") : qsTrId("playerHardware")
                    }
                    Rectangle { width: parent.width; height: 1; color: "#30ffffff" }
                    MenuRow {
                        width: parent.width
                        check: false
                        label: qsTrId("playerStatistics")
                        detail: "I"
                        onClicked: {
                            menu.mpv.command(["script-binding", "stats/display-stats-toggle"])
                            menu.done()
                        }
                    }
                }

                // This episode's copies, in the core's order: a pick is the
                // title's release, as in the title page's drawer.
                Column {
                    visible: menu.page === "source"
                    width: parent.width

                    Note {
                        visible: !menu.copies.listed || menu.copies.errorStatus >= 0
                                 || menu.copies.sources.length === 0
                        text: menu.copies.errorStatus >= 0 ? qsTrId("playerSourcesUnavailable")
                            : menu.copies.listed ? qsTrId("playerNoCopiesEpisode") : qsTrId("playerLookingSources")
                    }
                    Repeater {
                        model: menu.copies.sources
                        delegate: MenuRow {
                            required property var modelData
                            required property int index
                            objectName: "copy-" + index
                            width: parent.width
                            implicitHeight: 52
                            label: menu.copyLabel(modelData)
                            note: menu.copyNote(modelData)
                            detail: [modelData.size > 0 ? Words.bytes(modelData.size) : "",
                                     modelData.seeders > 0 ? qsTrId("playerSeedCount", modelData.seeders) : ""]
                                    .filter(p => p).join(" · ")
                            current: index === menu.playing
                            onClicked: {
                                if (!current)
                                    menu.pickCopy(index)
                                menu.done()
                            }
                        }
                    }
                }

                // For this film only: speed is never kept.
                Column {
                    visible: menu.page === "speed"
                    width: parent.width

                    Repeater {
                        model: menu.rates
                        delegate: MenuRow {
                            required property real modelData
                            objectName: "speed-" + modelData
                            width: parent.width
                            label: menu.rate(modelData)
                            current: Math.abs(menu.mpv.speed - modelData) < 0.001
                            onClicked: menu.mpv.set("speed", modelData)
                        }
                    }
                }

                Column {
                    visible: menu.page === "picture"
                    width: parent.width

                    Repeater {
                        model: 3
                        delegate: MenuRow {
                            required property int index
                            objectName: "fit-" + index
                            width: parent.width
                            label: menu.fits[index]
                            current: menu.mpv.fit === index
                            onClicked: menu.mpv.setFit(index)
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: "#30ffffff" }
                    // Off by default: it sharpens lines and wipes grain, which
                    // some like and others call damage.
                    Repeater {
                        model: [["", ""], ["a", "1080p"], ["b", "720p"], ["c", "480p"]]
                        delegate: MenuRow {
                            required property var modelData
                            objectName: "anime4k-" + (modelData[0] || "off")
                            width: parent.width
                            label: modelData[0] === "" ? qsTrId("playerAnime4kOff") : "Anime4K " + modelData[0].toUpperCase()
                            detail: modelData[1]
                            current: menu.mpv.anime4k === modelData[0]
                            onClicked: menu.mpv.setAnime4k(modelData[0])
                        }
                    }
                }

                Column {
                    visible: menu.page === "chapters"
                    width: parent.width

                    Repeater {
                        model: menu.page === "chapters" ? menu.mpv.chapters : []
                        delegate: MenuRow {
                            required property var modelData
                            required property int index
                            objectName: "chapter-" + index
                            width: parent.width
                            label: menu.chapterLabel(index)
                            detail: Words.clock(modelData.time)
                            current: menu.mpv.chapter === index
                            onClicked: menu.mpv.set("chapter", index)
                        }
                    }
                }

                Column {
                    visible: menu.page === "decoding"
                    width: parent.width

                    MenuRow {
                        objectName: "hardware"
                        width: parent.width
                        label: qsTrId("playerHardware")
                        current: menu.mpv.hwdec !== "no"
                        // mpv's own value for turning it on: only the
                        // methods known to decode correctly.
                        onClicked: menu.mpv.set("hwdec", "auto-safe")
                    }
                    MenuRow {
                        objectName: "software"
                        width: parent.width
                        label: qsTrId("playerSoftware")
                        current: menu.mpv.hwdec === "no"
                        onClicked: menu.mpv.set("hwdec", "no")
                    }
                }
            }
        }
    }

    component PageRow: MenuRow {
        id: entry
        // The page it opens.
        property string shows
        property string value
        objectName: "page-" + shows
        width: parent.width
        check: false
        opens: true
        label: menu.titles[shows] ?? ""
        detail: value
        onClicked: menu.page = entry.shows
    }

    component Note: Text {
        width: parent.width
        leftPadding: 16
        rightPadding: 12
        topPadding: 16
        bottomPadding: 8
        wrapMode: Text.Wrap
        color: "#ccffffff"
        font.family: Tokens.fontSans
        font.pixelSize: 14
    }
}
