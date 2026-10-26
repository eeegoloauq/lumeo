pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// What plays, chosen in one place (decisions/sources.md): the
// best copy of each episode, the releases on disk, every copy of the
// current one by resolution, and a folder on this computer. A pick is the
// title's release, which the next episode goes on from.
Drawer {
    id: drawer

    required property SourceChoice choice
    // A series' episodes, for "13 of 26"; none for a film.
    property var episodes: []
    // Opened by Play with "Ask every time": the copy picked plays.
    property bool asking

    // The way to add a source addon.
    signal addSource()

    readonly property bool film: episodes.length === 0
    // Why the last pick did not take.
    property string refusal

    // The rows, in order: what kind of row and what it shows.
    readonly property var rows: {
        const c = choice
        const out = [{ kind: "best", on: !c.chosen }]
        if (c.folders.length) {
            out.push({ kind: "heading", text: qsTrId("downloadsOnDisk") })
            c.folders.forEach((f, i) => out.push({ kind: "folder", index: i, folder: f }))
        }
        // One group per resolution from the sharpest down, each in the
        // order the core ranked it.
        const groups = new Map()
        c.sources.forEach((s, i) => {
            const r = s.release?.resolution || qsTrId("downloadsOther")
            if (!groups.has(r))
                groups.set(r, [])
            groups.get(r).push({ kind: "copy", index: i, source: s })
        })
        const sharp = r => parseInt(r) || 0
        for (const r of [...groups.keys()].sort((a, b) => sharp(b) - sharp(a))) {
            out.push({ kind: "heading", text: r })
            out.push(...groups.get(r))
        }
        if (!c.sources.length && c.listed)
            out.push({ kind: "why" })
        if (Core.onThisMachine)
            out.push({ kind: "link" })
        return out
    }

    function folderName(f) {
        if (f.dir) {
            const parts = f.dir.split(/[/\\]/).filter(p => p !== "")
            return parts.slice(Math.max(0, parts.length - 2)).join(" › ")
        }
        return [Words.sourceTitle(f.source), f.source.release?.resolution ?? "", f.folder ?? ""]
               .filter(p => p !== "").join(" · ")
    }

    // How many of the released episodes of its seasons the folder holds.
    function have(f) {
        const seasons = new Set((f.episodes ?? []).map(e => e.season))
        const total = episodes.filter(e => seasons.has(e.season)
                                      && !(e.released && new Date(e.released) > new Date())).length
        const count = (f.episodes ?? []).length
        return total < count ? String(count) : qsTrId("itemReleaseHave").arg(count).arg(total)
    }

    function languages(s) {
        const codes = (s.languages ?? []).map(l => l.toUpperCase())
        return codes.length <= 3 ? codes : codes.slice(0, 3).concat([qsTrId("downloadsMoreLanguages", codes.length - 3)])
    }

    function act(row) {
        refusal = ""
        switch (row.kind) {
        case "best":
            choice.chooseBest()
            break
        case "folder":
            choice.chooseFolder(row.index)
            break
        case "copy":
            choice.choose(row.index, asking)
            break
        case "link": {
            const linked = path => {
                choice.link(path)
                drawer.close()
            }
            if (film)
                Desktop.pickFile(qsTrId("itemReleaseFileTitle"), linked)
            else
                Desktop.pickFolder(qsTrId("itemReleaseFolderTitle"), "", linked)
            return
        }
        case "why":
            if (choice.empty === "addons")
                drawer.addSource()
            else
                choice.load()
            break
        default:
            return
        }
        close()
    }

    edge: Qt.RightEdge
    width: Math.min(520, parent.width)
    height: parent.height
    modal: true
    dim: true
    padding: 0
    Overlay.modal: Rectangle { color: "#80000000" }
    background: Rectangle { color: Tokens.floating }

    // A download may have finished since the drawer was last open.
    onAboutToShow: {
        refusal = ""
        choice.loadFolders()
    }
    // The keyboard opens on the copy Play would start.
    onOpened: {
        const at = rows.findIndex(r => r.kind === "copy" && r.index === choice.picked)
        list.currentIndex = at >= 0 ? at : 0
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
        list.forceActiveFocus()
    }
    onClosed: asking = false

    Connections {
        target: drawer.choice
        function onRefused(reason, status) {
            drawer.refusal = status === 422 ? qsTrId("itemReleaseFolderEmpty")
                                            : qsTrId("itemReleaseNotChosen").arg(reason)
            drawer.open()
        }
    }

    contentItem: Column {
        Item {
            width: parent.width
            height: 64

            Row {
                anchors { left: parent.left; leftMargin: 24; verticalCenter: parent.verticalCenter }
                spacing: 10

                Text {
                    visible: drawer.choice.season > 0
                    text: qsTrId("downloadsSeasonEpisode").arg(drawer.choice.season).arg(drawer.choice.episode)
                    color: Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.baseline: parent.children[0].baseline
                    text: qsTrId("downloadsCopyCount", drawer.choice.sources.length)
                    color: drawer.choice.season > 0 ? Tokens.muted : Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: drawer.choice.season > 0 ? Tokens.textData : 18
                    font.weight: drawer.choice.season > 0 ? Font.Normal : Font.DemiBold
                }
            }
            IconButton {
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                glyph: "close"
                tip: qsTrId("downloadsCloseSources")
                onClicked: drawer.close()
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Tokens.line
            }
        }

        Text {
            x: 24
            width: parent.width - 48
            topPadding: 12
            visible: drawer.refusal !== ""
            text: drawer.refusal
            color: Tokens.warn
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            wrapMode: Text.Wrap
        }

        ListView {
            id: list
            objectName: "sources"
            width: parent.width
            height: drawer.height - 64 - (drawer.refusal !== "" ? 40 : 0)
            clip: true
            model: drawer.rows
            bottomMargin: 24
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 0
            Keys.onReturnPressed: drawer.act(drawer.rows[currentIndex])
            Keys.onEnterPressed: drawer.act(drawer.rows[currentIndex])

            delegate: ItemDelegate {
                id: row
                required property int index
                required property var modelData
                readonly property var r: modelData
                readonly property bool lit: ListView.isCurrentItem && list.activeFocus

                objectName: r.kind === "copy" ? "copy-" + r.index : r.kind
                width: list.width
                enabled: r.kind !== "heading"
                focusPolicy: Qt.NoFocus
                leftPadding: 24
                rightPadding: 24
                topPadding: r.kind === "heading" ? 16 : 10
                bottomPadding: r.kind === "heading" ? 4 : 10
                onClicked: drawer.act(r)
                HoverHandler { cursorShape: row.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }

                background: Rectangle {
                    color: row.r.kind === "copy" && row.r.index === drawer.choice.picked ? Tokens.tint
                         : row.lit || row.hovered ? Tokens.hover : "transparent"
                    border.width: row.lit ? 2 : 0
                    border.color: Theme.accent
                }

                contentItem: Loader {
                    sourceComponent: row.r.kind === "heading" ? heading
                                   : row.r.kind === "copy" ? copy
                                   : line

                    Component {
                        id: heading
                        Text {
                            text: row.r.text
                            color: Tokens.muted
                            font.family: Tokens.fontSans
                            font.pixelSize: Tokens.textData
                        }
                    }

                    // A choice that is not a copy: a check for the one in
                    // use, its name, and what it holds.
                    Component {
                        id: line
                        Row {
                            spacing: 12
                            Item {
                                width: 18
                                height: 18
                                anchors.verticalCenter: parent.verticalCenter
                                Glyph {
                                    anchors.centerIn: parent
                                    visible: row.r.on || row.r.folder?.current || false
                                    glyph: "check"
                                    size: 18
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    text: {
                                        switch (row.r.kind) {
                                        case "best": return qsTrId("itemReleaseAutomatic")
                                        case "folder": return drawer.folderName(row.r.folder)
                                        case "link": return drawer.film ? qsTrId("itemReleaseFile") : qsTrId("itemReleaseFolder")
                                        case "why":
                                            switch (drawer.choice.empty) {
                                            case "addons": return qsTrId("playerNoSourceAddons")
                                            case "failed": return drawer.choice.failed.map(f => Words.providerFailure(f)).join(" · ")
                                            case "today": return qsTrId("playerOutTodayNoCopies")
                                            case "yesterday": return qsTrId("playerOutYesterdayNoCopies")
                                            }
                                            return qsTrId("playerNoCopies")
                                        }
                                        return ""
                                    }
                                    color: Tokens.text
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textCard
                                }
                                Text {
                                    visible: text !== ""
                                    text: {
                                        switch (row.r.kind) {
                                        case "best": return drawer.film ? qsTrId("itemReleaseBestFilm") : qsTrId("itemReleaseBest")
                                        case "folder":
                                            return [row.r.folder.directorsCut ? qsTrId("downloadsDirectorsCut") : "",
                                                    drawer.film ? "" : drawer.have(row.r.folder)]
                                                   .filter(p => p !== "").join(" · ")
                                        case "why":
                                            return drawer.choice.empty === "addons" ? qsTrId("playerAddSource")
                                                                                     : qsTrId("commonTryAgain")
                                        }
                                        return ""
                                    }
                                    color: Tokens.muted
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                            }
                        }
                    }

                    // A copy: who made it and what kind, its size and swarm,
                    // the folder in its pack, its languages. The release
                    // name waits in the tooltip.
                    Component {
                        id: copy
                        Column {
                            id: entry
                            readonly property var s: row.r.source
                            spacing: 6
                            width: list.width - 48
                            // What this machine cannot decode is a fact about the
                            // row, not the film: the same copy plays on the next
                            // machine. Marked rather than hidden.
                            ToolTip {
                                text: [entry.s.rawName, entry.s.path ?? "",
                                       MpvFacts.gapSentence(entry.s.release ?? {})].filter(p => p).join("\n")
                                visible: row.hovered
                                delay: 600
                            }

                            Item {
                                width: parent.width
                                height: name.implicitHeight
                                Text {
                                    id: name
                                    width: parent.width - facts.implicitWidth - 16
                                    text: [entry.s.local ? entry.s.release?.resolution ?? "" : "",
                                           Words.sourceTitle(entry.s) || "—"].filter(p => p).join(" · ")
                                    color: Tokens.text
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textCard
                                    font.weight: row.r.index === drawer.choice.picked ? Font.DemiBold : Font.Normal
                                    elide: Text.ElideRight
                                }
                                Text {
                                    id: facts
                                    anchors.right: parent.right
                                    text: {
                                        const s = entry.s
                                        const status = s.local === "done" ? qsTrId("downloadsOnDiskLower")
                                                     : s.local === "partial" ? qsTrId("downloadsPartOnDisk")
                                                     : s.seeders > 0 ? qsTrId("downloadsSeedCount", s.seeders) : ""
                                        return [Words.bytes(s.size ?? 0), status].filter(p => p).join(" · ")
                                    }
                                    color: Tokens.dim
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                            }
                            Text {
                                visible: text !== ""
                                width: parent.width
                                text: entry.s.folder ?? ""
                                color: Tokens.dim
                                font.family: Tokens.fontSans
                                font.pixelSize: Tokens.textData
                                elide: Text.ElideRight
                            }
                            Row {
                                spacing: 4
                                Repeater {
                                    model: drawer.languages(entry.s)
                                    Rectangle {
                                        required property string modelData
                                        width: code.implicitWidth + 12
                                        height: code.implicitHeight + 4
                                        radius: 4
                                        color: Tokens.tint
                                        Text {
                                            id: code
                                            anchors.centerIn: parent
                                            text: parent.modelData
                                            color: Tokens.text
                                            font.family: Tokens.fontSans
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                        }
                                    }
                                }
                                Text {
                                    visible: !(entry.s.languages ?? []).length
                                    text: qsTrId("downloadsNoLanguages")
                                    color: Tokens.muted
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                                Text {
                                    objectName: "decoderMark"
                                    visible: text !== ""
                                    leftPadding: 4
                                    text: MpvFacts.answered ? MpvFacts.gapMark(entry.s.release ?? {}) : ""
                                    color: Tokens.warn
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                                Text {
                                    visible: entry.s.directorsCut ?? false
                                    leftPadding: 4
                                    text: qsTrId("downloadsDirectorsCut")
                                    color: Tokens.warn
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                                Text {
                                    visible: entry.s.lastUsed ?? false
                                    leftPadding: 4
                                    text: qsTrId("downloadsLastUsed")
                                    color: Tokens.muted
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textData
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
