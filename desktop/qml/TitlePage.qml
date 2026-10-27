pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo
import "format.js" as Format

// Everything about one title on one page, a film and a series alike. Play
// and its copies belong to whatever Play would start, not to the title.
ShellPage {
    id: page

    // The catalogue's row the page was opened from.
    required property var item
    // Play was pressed on the way here: the first list of copies starts.
    property bool play
    // The episode to open on, {season, episode}, in place of where watching
    // goes on: a line of the history, a new episode.
    property var at: null

    // Play started this download.
    signal watch(string downloadId, string name)
    // The trailer to play, as Player.trailer.
    signal trailer(var trailer, string name)
    // The way to add a source addon, which none ships with.
    signal addSource()

    readonly property var shown: about.status === Title.Ready ? about.item : page.item
    readonly property var episodes: about.item.episodes ?? []
    readonly property bool series: episodes.length > 0
    // Specials come as season 0: offered, but not first.
    readonly property var seasons: {
        const all = [...new Set(episodes.map(e => e.season))].sort((a, b) => a - b)
        return all.length > 1 && all[0] === 0 ? all.slice(1).concat([0]) : all
    }
    // The season shown, once one is picked; until then the page opens where
    // watching goes on.
    property int seasonPicked: -1
    // A card chosen on this page.
    property var picked: null
    readonly property var resumed: {
        const at = page.at ?? about.opening
        return episodes.find(e => e.season === at.season && e.number === at.episode) ?? null
    }
    readonly property int season: seasonPicked >= 0 ? seasonPicked : resumed?.season ?? seasons[0] ?? 0
    readonly property var inSeason: episodes.filter(e => e.season === season)
    // The one current episode: Play plays it and the copies are its. The one
    // picked or resumed in the season shown, else where that season was left,
    // else its first aired; a season with nothing aired keeps the one before,
    // its dated cards are there to read, not to play.
    readonly property var current: {
        if (!series)
            return null
        if (picked?.season === season)
            return picked
        if (resumed?.season === season)
            return resumed
        return leftAt() ?? inSeason.find(e => !upcoming(e)) ?? picked ?? resumed ?? inSeason[0]
    }
    // The episode the copies are listed for: the current one, once a run of
    // clicks along the season has settled on it, so a provider is not asked
    // for every card on the way. Unpicked, it follows at once: as the title
    // arrives these bindings pass through stale values (season 0, a special,
    // for a moment), and the list is asked only once they settle.
    property var listed: null
    onCurrentChanged: {
        if (!listed || !picked)
            listed = current
        else
            settle.restart()
    }

    // The trailers the metadata names, in its order, which mpv plays through
    // yt-dlp; the banner plays the first.
    readonly property var trailerUrls: MpvFacts.ytdl ? about.item.trailers ?? [] : []
    // How long the page is up before the trailer plays in its banner; a test
    // shortens it.
    property int previewDelay: 3000

    readonly property string playText: {
        const s = current?.season, e = current?.number
        if (resume)
            return series ? qsTrId("playerResumeEpisode").arg(s).arg(e) : qsTrId("playerResume")
        return series ? qsTrId("playerPlayEpisode").arg(s).arg(e) : qsTrId("commonPlay")
    }

    readonly property var watched: entryOf(current)
    // Far enough in to go on from, and not at the end.
    readonly property bool resume: !!watched && watched.position > 10 && watched.duration > watched.position

    function upcoming(episode) {
        return !!episode.released && new Date(episode.released) > new Date()
    }

    function same(a, b) {
        return !!a && !!b && a.season === b.season && a.number === b.number
    }

    // Where the season shown was left, by the core's rule for the whole
    // title: the episode of it watched last while part way, else the one
    // after, once it is out.
    function leftAt() {
        let last = null
        for (const e of about.progress.entries ?? [])
            if (e.season === season && (!last || e.updatedAt > last.updatedAt))
                last = e
        if (!last)
            return null
        const at = inSeason.find(e => e.number === last.episode)
        const after = inSeason.find(e => e.number === last.episode + 1)
        return last.watched && last.position === 0 && after && !upcoming(after) ? after : at ?? null
    }

    function entryOf(episode) {
        const season = episode?.season ?? 0, number = episode?.number ?? 0
        return (about.progress.entries ?? []).find(e => e.season === season && e.episode === number)
    }

    // Plays [episode] now, its list on its way or not. With "Ask every
    // time" a list already here opens first, and the copy picked plays.
    function playEpisode(episode) {
        settle.stop()
        if (!episode || same(episode, listed)) {
            if (Preferences.current.askCopy && copies.sources.length > 0) {
                drawer.asking = true
                drawer.open()
                return
            }
            copies.start()
            return
        }
        picked = episode
        listed = episode
        copies.startWhenReady = true
    }

    // The keyboard onto card [index] of the season shown, or past either end
    // into the next season; the tabs are the mouse's way between seasons.
    // Specials are not part of the run.
    function step(index, by) {
        const to = index + by
        if (to >= 0 && to < inSeason.length) {
            focusCard(to)
            return
        }
        const runs = seasons.filter(s => s > 0)
        const at = runs.indexOf(season)
        if (at < 0 || at + by < 0 || at + by >= runs.length)
            return
        seasonPicked = runs[at + by]
        focusCard(by > 0 ? 0 : inSeason.length - 1)
    }

    function focusCard(index) {
        strip.positionViewAtIndex(index, ListView.Contain)
        strip.itemAtIndex(index)?.forceActiveFocus(Qt.TabFocusReason)
    }

    Timer {
        id: settle
        interval: 400
        onTriggered: page.listed = page.current
    }

    function playName() {
        if (!current)
            return shown.title
        return qsTrId("itemPlaybackTitle").arg(shown.title)
            .arg(Words.padded(current.season)).arg(Words.padded(current.number))
    }

    scrolled: view.contentY > 12

    // Back from the player, or from a page over this one: once something was
    // watched, the page opens where watching now goes on.
    onVisibleChanged: if (visible) about.refreshProgress()

    Title {
        id: about
        itemId: page.item.id
        onMoved: {
            page.at = null
            page.seasonPicked = -1
            page.picked = null
        }
    }

    Mine {
        id: mine
        itemId: page.item.id
        onRefused: what => {
            const said = {
                add: qsTrId("libraryCouldNotAdd"),
                remove: qsTrId("libraryCouldNotRemove"),
                rate: qsTrId("libraryRatingNotSaved"),
                clear: qsTrId("libraryRatingNotRemoved"),
            }[what]
            refusal.parent = what === "add" || what === "remove" ? listButton : ratingButton
            refusal.show(said, 3000)
        }
    }

    // What the core refused, over the button that asked.
    ToolTip { id: refusal }

    SourceChoice {
        id: copies
        // Named once the title is here: a series' first list is for its
        // episode, not for the title as a whole.
        itemId: about.status === Title.Ready ? page.item.id : ""
        season: page.listed?.season ?? 0
        episode: page.listed?.number ?? 0
        released: page.listed?.released ?? ""
        startWhenReady: page.play
        onStarted: id => page.watch(id, page.playName())
    }

    SourcesDrawer {
        id: drawer
        objectName: "sourcesDrawer"
        choice: copies
        episodes: page.episodes
        onAddSource: page.addSource()
    }

    Loading {
        anchors.centerIn: parent
        waiting: about.status === Title.Loading
    }

    Trouble {
        anchors.centerIn: parent
        visible: about.status === Title.Failed
        title: qsTrId("itemLoadFailed")
        hint: qsTrId("itemLoadFailedHint")
        detail: about.error
        action: qsTrId("commonTryAgain")
        onActed: about.load()
    }

    Flickable {
        id: view
        anchors.fill: parent
        visible: about.status === Title.Ready
        contentHeight: banner.height + (page.series ? block.height : 0)
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { flickable: view }

        // What a series' banner leaves room for under it: the seasons, the
        // line about the current episode and a whole card of the strip.
        readonly property real reveal: page.series ? 54 + 40 + strip.height + 16 : 0

        Item {
            id: banner
            width: view.width
            // What the window leaves above the season block, between a floor
            // and a ceiling; a film's page is its banner, to the floor. What it
            // holds can make it taller, and the page then scrolls.
            height: Math.max(Theme.whole(view.reveal > 0 ? Math.max(420, Math.min(720, view.height - view.reveal))
                                                         : Math.max(420, view.height),
                                         Screen.devicePixelRatio),
                             Theme.whole(words.implicitHeight + 90 + 26, Screen.devicePixelRatio))

            Banner {
                anchors.fill: parent
                url: page.shown.background ?? ""

                // The trailer in place of the backdrop, muted, a moment after
                // the page is up. Once it has ended or the page was left it
                // stays gone: back from a film, the page is for what is next.
                Loader {
                    id: preview
                    property bool over: false
                    anchors.fill: parent
                    active: LocalSettings.trailerPreviews && page.trailerUrls.length > 0 && page.visible
                            && previewDue.done && !over
                    onActiveChanged: if (!active && previewDue.done) over = true

                    sourceComponent: MpvItem {
                        objectName: "trailerPreview"
                        keepsLog: false
                        opacity: hasPicture && !ended ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 600 } }
                        // Filling the banner would leave an upright one a sliver.
                        onAspectChanged: if (aspect > 0 && aspect < 1) setFit(0)
                        // Scrolled to the episodes, it waits for the banner.
                        readonly property bool away: view.contentY > banner.height / 2
                        onAwayChanged: set("pause", away)
                        // Faded out at its end, then gone.
                        onOpacityChanged: if (opacity === 0 && ended) preview.over = true
                        onLoadFailed: preview.over = true
                        Component.onCompleted: {
                            set("mute", true)
                            set("volume", LocalSettings.volume)
                            // A banner, not a cinema: 4K would cost the network for nothing.
                            set("ytdl-format", "bv*[height<=1080]+ba/b")
                            // Filling the banner as its artwork does, cut at the edges.
                            setFit(1)
                            open(page.trailerUrls[0])
                        }
                    }
                }
                Timer {
                    id: previewDue
                    property bool done: false
                    interval: page.previewDelay
                    running: about.status === Title.Ready && page.visible && !done
                    onTriggered: done = true
                }
            }
            // Its sound, while it plays.
            TintButton {
                objectName: "trailerSound"
                readonly property MpvItem trailerClip: preview.item as MpvItem
                anchors { right: parent.right; bottom: parent.bottom; margins: Tokens.gutter }
                visible: !!trailerClip && trailerClip.hasPicture && !trailerClip.ended
                glyph: trailerClip?.muted ?? true ? "volume_off" : "volume_up"
                tip: trailerClip?.muted ?? true ? qsTrId("itemTrailerSoundOn") : qsTrId("itemTrailerSoundOff")
                onClicked: trailerClip.set("mute", !trailerClip.muted)
            }

            Column {
                id: words
                x: Tokens.gutter
                width: parent.width - 2 * Tokens.gutter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 26

                Heading {
                    width: parent.width
                    item: page.shown
                    overviewWidth: 560
                    overviewLines: 4
                    overviewGap: 14
                    facts: {
                        const seasons = new Set(page.episodes.map(e => e.season).filter(s => s > 0))
                        return [Format.years(page.shown),
                                seasons.size ? qsTrId("itemSeasonCount", seasons.size) : "",
                                page.shown.runtime,
                                (page.shown.genres ?? []).slice(0, 3).join(" / ")]
                    }
                }
                Item { width: 1; height: 24 }
                Row {
                    spacing: 16

                    PlayButton {
                        objectName: "titlePlay"
                        enabled: copies.playable
                        text: page.playText
                        onClicked: page.playEpisode(page.current)
                    }
                    // A film's copy Play would start, fetched without
                    // playing; once all of it is here the button goes, and
                    // the line under Play says On disk.
                    DownloadButton {
                        objectName: "filmDownload"
                        readonly property var mark: Downloads.marks[page.item.id]
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !page.series && !mark?.done
                        fraction: copies.starting ? 0 : mark?.fraction ?? -1
                        enabled: copies.picked >= 0 && !running
                        tip: running ? qsTrId("itemDownloadingPercent").arg(Math.floor(fraction * 100))
                                     : qsTrId("commonDownload")
                        onClicked: copies.download()
                    }
                    // What the viewer keeps and thinks of the title: quiet
                    // marks beside the one action, not second ones.
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        TintButton {
                            objectName: "trailerButton"
                            visible: page.trailerUrls.length > 0
                            glyph: "movie"
                            tip: qsTrId("itemTrailer")
                            onClicked: page.trailer({
                                urls: page.trailerUrls,
                                play: copies.playable ? page.playText : "",
                                played: () => page.playEpisode(page.current),
                            }, page.shown.title)
                        }
                        TintButton {
                            id: listButton
                            objectName: "listButton"
                            enabled: mine.known
                            glyph: mine.inList ? "check" : "add"
                            tip: mine.inList ? qsTrId("libraryRemoveFromList") : qsTrId("libraryAddToList")
                            onClicked: mine.toggle()
                        }
                        RatingButton {
                            id: ratingButton
                            objectName: "ratingButton"
                            enabled: mine.known
                            score: mine.score
                            onRated: score => mine.rate(score)
                            onCleared: mine.clear()
                        }
                        // Says it copied for a moment, on itself: a button that
                        // looks the same afterwards gets pressed twice.
                        TintButton {
                            id: share
                            objectName: "shareButton"
                            visible: about.link !== ""
                            glyph: copied.running ? "check" : "ios_share"
                            tip: copied.running ? qsTrId("itemLinkCopied") : qsTrId("itemShare")
                            onClicked: {
                                about.copyLink()
                                copied.restart()
                            }

                            Timer { id: copied; interval: 2000 }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: page.resume
                        text: page.resume ? qsTrId("playerClockLeft").arg(
                                  Words.clock(page.watched.duration - page.watched.position)) : ""
                        color: Tokens.dim
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textMeta
                        font.weight: Font.Medium
                    }
                }
                Item { width: 1; height: 8 }
                PlayLine {
                    width: parent.width
                    choice: copies
                    onAddSource: page.addSource()
                    onChoose: drawer.open()
                }
            }
        }

        Column {
            id: block
            y: banner.height
            // Why the season's download stopped, until the next try.
            property string trouble

            Connections {
                target: about
                function onSeasonFailed(reason) { block.trouble = qsTrId("itemSeasonStartFailed").arg(reason) }
            }
            width: view.width
            visible: page.series

            // A season is navigation, not a choice of what plays: the one
            // shown is raised, not in the accent.
            Item {
                x: Tokens.gutter
                width: parent.width - 2 * Tokens.gutter
                height: 54

                Rectangle {
                    anchors { left: parent.left; right: tabs.right; verticalCenter: tabs.verticalCenter }
                    height: 1
                    color: Tokens.line
                    visible: page.seasons.length === 1
                }
                Flow {
                    id: tabs
                    width: parent.width - seasonDownload.width - 12
                    spacing: 8
                    visible: page.seasons.length > 1

                    Repeater {
                        model: page.seasons
                        AbstractButton {
                            id: tab
                            required property int modelData
                            readonly property bool lit: modelData === page.season
                            objectName: "season-" + modelData
                            implicitHeight: 36
                            implicitWidth: name.implicitWidth + 28
                            focusPolicy: Qt.TabFocus
                            onClicked: page.seasonPicked = modelData
                            HoverHandler { cursorShape: Qt.PointingHandCursor }

                            background: Rectangle {
                                radius: Tokens.radiusControl
                                color: tab.lit ? Tokens.raised : tab.hovered ? Tokens.hover : "transparent"
                                border.width: tab.visualFocus ? 2 : 1
                                border.color: tab.visualFocus ? Theme.accent : tab.lit ? "transparent" : Tokens.line
                            }
                            contentItem: Text {
                                id: name
                                text: tab.modelData === 0 ? qsTrId("itemSpecials")
                                                          : qsTrId("itemSeason").arg(tab.modelData)
                                color: tab.lit ? Tokens.text : Tokens.dim
                                font.family: Tokens.fontSans
                                font.pixelSize: Tokens.textCard
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }

                // Every released episode of the season, each the copy Play
                // would start for it.
                DownloadButton {
                    id: seasonDownload
                    objectName: "seasonDownload"
                    readonly property var out: page.inSeason.filter(e => !page.upcoming(e))
                    // This season's downloads by episode, failed ones aside.
                    readonly property var rows: {
                        const rows = {}
                        for (const d of Downloads.all)
                            if (d.itemId === page.item.id && d.season === page.season && d.state !== "failed")
                                rows[d.episode] = d
                        return rows
                    }
                    readonly property int have: out.filter(e => rows[e.number]?.state === "done").length
                    readonly property bool queued: about.queueing
                                                   || Object.values(rows).some(d => d.state === "active")
                    readonly property string name: page.season === 0 ? qsTrId("itemSpecialsDownload")
                                                                     : qsTrId("itemSeasonDownload").arg(page.season)
                    readonly property string named: page.season === 0 ? qsTrId("itemSpecials")
                                                                      : qsTrId("itemSeason").arg(page.season)

                    anchors { right: parent.right; verticalCenter: tabs.verticalCenter }
                    visible: out.length > 0
                    done: have === out.length
                    fraction: !queued ? -1 : out.map(e => {
                        const d = rows[e.number]
                        if (!d)
                            return 0
                        if (d.state === "done")
                            return 1
                        return d.progress?.total > 0 ? d.progress.completed / d.progress.total : 0
                    }).reduce((a, b) => a + b, 0) / out.length
                    tip: done ? qsTrId("itemDownloadOnDisk").arg(named)
                       : queued ? qsTrId("itemDownloadProgress").arg(named).arg(have).arg(out.length)
                       : have > 0 ? qsTrId("itemDownloadRest").arg(name)
                       : qsTrId("itemDownloadNamed").arg(name)
                    onClicked: {
                        block.trouble = ""
                        about.downloadSeason(out)
                    }
                }
            }

            Text {
                x: Tokens.gutter
                width: parent.width - 2 * Tokens.gutter
                visible: block.trouble !== ""
                bottomPadding: 8
                text: block.trouble
                color: Tokens.warn
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                wrapMode: Text.Wrap
            }

            // Which episode is current, above the strip so it stays put: its
            // name and date, and the same height without one.
            Text {
                x: Tokens.gutter
                width: parent.width - 2 * Tokens.gutter
                height: 40
                text: {
                    const e = page.current
                    if (!e || e.season !== page.season)
                        return ""
                    const name = e.title && e.title !== "Episode " + e.number
                               ? qsTrId("itemEpisodeNamed").arg(e.number).arg(e.title)
                               : qsTrId("itemEpisodeNumber").arg(e.number)
                    if (!e.released)
                        return name
                    return name + "&nbsp;&nbsp;&nbsp;<font color='" + Tokens.muted + "'>"
                         + Words.shortDate(e.released) + "</font>"
                }
                textFormat: Text.StyledText
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 17
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Strip {
                id: strip
                objectName: "episodes"
                width: parent.width
                height: 300 * 9 / 16 + 64 + 4
                topMargin: 2
                spacing: 14
                model: page.inSeason
                // At the current episode when a season comes up, and on it the
                // keyboard, so the arrows work without a click first, unless
                // the keyboard is already somewhere on the page.
                onModelChanged: Qt.callLater(() => {
                    const at = page.inSeason.findIndex(e => page.same(e, page.current))
                    if (at < 0)
                        return
                    place(at)
                    if (page.Window.activeFocusItem === page)
                        itemAtIndex(at)?.forceActiveFocus(Qt.TabFocusReason)
                })

                delegate: EpisodeCard {
                    id: card
                    required property int index
                    required property var modelData
                    readonly property var entry: page.entryOf(card.modelData)
                    readonly property bool onDisk: Downloads.marks[page.item.id + "/" + card.modelData.season + "/" + card.modelData.number]?.done ?? false

                    episode: card.modelData
                    selected: page.same(card.modelData, page.current)
                    // One stop for Tab: the current card, else the first.
                    focusPolicy: selected || (card.index === 0 && page.current?.season !== page.season)
                                 ? Qt.TabFocus : Qt.NoFocus
                    stills: Preferences.current.episodeArtwork ?? "show"
                    watched: card.entry?.watched ?? false
                    bar: !card.entry ? 0 : card.entry.position > 0 && card.entry.duration > 0
                                      ? card.entry.position / card.entry.duration : card.entry.watched ? 1 : 0
                    mark: Downloads.marks[page.item.id + "/" + card.modelData.season + "/" + card.modelData.number]
                    frame: EpisodeFrames.known[page.item.id + "/" + card.modelData.season + "/" + card.modelData.number] ?? ""
                    // With no provider to ask, only what is on disk plays.
                    unreachable: copies.unreachable && !card.onDisk
                    onChosen: page.picked = card.modelData
                    onPlayed: page.playEpisode(card.modelData)
                    onStep: by => page.step(card.index, by)
                }
            }
            Item { width: 1; height: 16 }
        }
    }
}
