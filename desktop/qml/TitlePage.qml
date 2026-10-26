pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
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

    // Play started this download.
    signal watch(string downloadId, string name)
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
        const at = about.opening
        return episodes.find(e => e.season === at.season && e.number === at.episode) ?? null
    }
    readonly property int season: seasonPicked >= 0 ? seasonPicked : resumed?.season ?? seasons[0] ?? 0
    readonly property var inSeason: episodes.filter(e => e.season === season)
    // The one current episode: Play plays it and the copies are its. The one
    // picked or resumed in the season shown, else its first aired; a season
    // with nothing aired keeps the one before, its dated cards are there to
    // read, not to play.
    readonly property var current: {
        if (!series)
            return null
        if (picked?.season === season)
            return picked
        if (resumed?.season === season)
            return resumed
        return inSeason.find(e => !upcoming(e)) ?? picked ?? resumed ?? inSeason[0]
    }
    // The episode the copies are listed for: the current one, once a run of
    // clicks along the season has settled on it, so a provider is not asked
    // for every card on the way.
    property var listed: null
    onCurrentChanged: {
        if (!listed)
            listed = current
        else
            settle.restart()
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

    function entryOf(episode) {
        const season = episode?.season ?? 0, number = episode?.number ?? 0
        return (about.progress.entries ?? []).find(e => e.season === season && e.episode === number)
    }

    // Plays [episode] now, its list on its way or not.
    function playEpisode(episode) {
        settle.stop()
        if (!episode || same(episode, listed)) {
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

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
        return (h > 0 ? h + ":" + Words.padded(m) : m) + ":" + Words.padded(s % 60)
    }

    scrolled: view.contentY > 12

    Title {
        id: about
        itemId: page.item.id
    }

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
                        text: {
                            const s = page.current?.season, e = page.current?.number
                            if (page.resume)
                                return page.series ? qsTrId("playerResumeEpisode").arg(s).arg(e)
                                                   : qsTrId("playerResume")
                            return page.series ? qsTrId("playerPlayEpisode").arg(s).arg(e)
                                               : qsTrId("commonPlay")
                        }
                        onClicked: page.playEpisode(page.current)
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: page.resume
                        text: page.resume ? qsTrId("playerClockLeft").arg(
                                  page.clock(page.watched.duration - page.watched.position)) : ""
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
                }
            }
        }

        Column {
            id: block
            y: banner.height
            width: view.width
            visible: page.series

            // A season is navigation, not a choice of what plays: the one
            // shown is raised, not in the accent.
            Item {
                x: Tokens.gutter
                width: parent.width - 2 * Tokens.gutter
                height: 54

                Rectangle {
                    anchors { left: parent.left; right: parent.right; verticalCenter: tabs.verticalCenter }
                    height: 1
                    color: Tokens.line
                    visible: page.seasons.length === 1
                }
                Flow {
                    id: tabs
                    width: parent.width
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
