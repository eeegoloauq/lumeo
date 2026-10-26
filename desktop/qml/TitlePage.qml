pragma ComponentBehavior: Bound

import QtQuick
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
    // The episode Play and the copies are for: the one the page opens on,
    // else the first that has aired.
    readonly property var current: {
        if (!series)
            return null
        const at = about.opening
        const now = new Date()
        return episodes.find(e => e.season === at.season && e.number === at.episode)
            ?? episodes.find(e => !e.released || new Date(e.released) <= now)
            ?? episodes[0]
    }
    readonly property var watched: {
        const season = current?.season ?? 0, episode = current?.number ?? 0
        return (about.progress.entries ?? []).find(e => e.season === season && e.episode === episode)
    }
    // Far enough in to go on from, and not at the end.
    readonly property bool resume: !!watched && watched.position > 10 && watched.duration > watched.position

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
        season: page.current?.season ?? 0
        episode: page.current?.number ?? 0
        released: page.current?.released ?? ""
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
        contentHeight: banner.height
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: banner
            width: view.width
            // A film's page is its banner, to a floor; what it holds can make
            // it taller, and the page then scrolls.
            height: Math.max(Theme.whole(Math.max(420, view.height), Screen.devicePixelRatio),
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
                        onClicked: copies.start()
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
    }
}
