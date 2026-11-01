pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// What the title page does, from any poster or card: one menu, opened where
// the right button, the Menu key or Shift+F10 asked for it (TitleActions).
// On the title's own page, ⋯ beside Play holds what is not beside it, and an
// episode's card or a season's tab what is about that episode or season
// (decisions/interface.md, A title's menu).
Menu {
    id: titleMenu
    objectName: "titleMenu"

    // What it was opened on, as TitleActions.ask was given it.
    property var target: ({})
    readonly property var item: target.item ?? {}
    readonly property var episode: target.episode ?? null
    readonly property bool series: item.kind === "series"
    readonly property bool onPage: target.page === "title"
    readonly property bool seasonTab: target.season !== undefined
    // ⋯ beside Play on the title's own page: Play, My list, the score and a
    // film's download are beside it.
    readonly property bool header: onPage && !episode && !seasonTab
    readonly property bool upcoming: !!episode?.released && new Date(episode.released) > new Date()

    // The title and the viewer's marks on it, asked for each time the menu
    // opens; until they answer, the rows that need them wait.
    property Title about: null
    property Mine mine: null
    readonly property bool ready: !!about && about.status === Title.Ready
    readonly property var entries: ready ? about.progress.entries ?? [] : []
    // The film or the episode the rows about one viewing are for; null for a
    // series as a whole.
    readonly property var one: seasonTab ? null : episode ? {season: episode.season, episode: episode.number}
                                                          : series ? null : {season: 0, episode: 0}
    readonly property var entry: one ? entries.find(e => e.season === one.season && e.episode === one.episode) ?? null : null
    // Its download, the one on disk first when there are several.
    readonly property var download: {
        if (!one)
            return {}
        const all = Downloads.all.filter(d => d.itemId === item.id && d.season === one.season
                                         && d.episode === one.episode && d.state !== "failed")
        return all.find(d => d.state === "done") ?? all[0] ?? {}
    }
    // The score is the episode's on its card and its line in History, the
    // title's on a poster or a Continue watching card, whose episode is half
    // seen.
    readonly property bool scoresEpisode: !!episode && (onPage || !!target.history)
    readonly property var trailers: ready && MpvFacts.ytdl ? about.item.trailers ?? [] : []

    // A title to play, as the shell opens one, or its trailer.
    signal play(var item, var at)
    signal trailer(var trailer, string name)
    // A line for the toast.
    signal say(string text)

    function show(target) {
        if (opened)
            close()
        retire()
        titleMenu.target = target
        about = titleMaker.createObject(titleMenu, {itemId: target.item.id}) as Title
        const own = !!target.episode && (target.page === "title" || !!target.history)
        mine = mineMaker.createObject(titleMenu, {
            itemId: target.item.id,
            season: own ? target.episode.season : 0,
            episode: own ? target.episode.number : 0,
        }) as Mine
        popup(target.source, target.x, target.y)
    }

    // The last title's objects go, once what they were sending has landed.
    function retire() {
        const old = about
        if (old && old.queueing)
            old.queueingChanged.connect(() => { if (!old.queueing) old.destroy() })
        else
            old?.destroy()
        mine?.destroy(10000)
        titleMenu.about = null
        titleMenu.mine = null
    }

    function rateText() {
        if (scoresEpisode)
            return qsTrId("menuRateEpisode")
        return series ? qsTrId("menuRateSeries") : qsTrId("menuRateFilm")
    }

    Component {
        id: titleMaker
        Title {
            onSeasonFailed: reason => titleMenu.say(qsTrId("menuDownloadFailed").arg(reason))
        }
    }
    Component {
        id: mineMaker
        Mine {
            id: marks
            onStored: TitleActions.changed(marks.itemId)
            onRefused: what => titleMenu.say({
                add: qsTrId("libraryCouldNotAdd"),
                remove: qsTrId("libraryCouldNotRemove"),
                rate: qsTrId("libraryRatingNotSaved"),
                clear: qsTrId("libraryRatingNotRemoved"),
            }[what])
        }
    }

    // The score picked after the menu has gone, where the menu was.
    RatingScale {
        id: scorePicker
        parent: titleMenu.parent
        score: titleMenu.mine?.score ?? 0
        onRated: n => titleMenu.mine?.rate(n)
        onCleared: titleMenu.mine?.clear()
    }

    padding: 6
    background: Rectangle {
        implicitWidth: 260
        radius: Tokens.radiusFloating
        color: Qt.alpha(Tokens.floating, 0.97)
        border.color: Tokens.rim
    }

    // A row with its icon; hidden rows take no room.
    component Choice: MenuItem {
        id: row
        property string glyph
        property bool danger
        property string detail
        // Whether it can be used now; a hidden row is disabled too, which
        // is what keeps the arrow keys off it.
        property bool usable: true
        readonly property color tone: !enabled ? Tokens.muted : danger ? Tokens.down : Tokens.text

        enabled: visible && usable
        height: visible ? implicitHeight : 0
        implicitHeight: 36
        leftPadding: 10
        rightPadding: 12
        background: Rectangle {
            radius: Tokens.radiusControl
            color: row.highlighted ? Tokens.hover : "transparent"
        }
        contentItem: Item {
            implicitWidth: icon.width + 12 + label.implicitWidth + (row.detail ? 12 + detailText.implicitWidth : 0)
            Glyph {
                id: icon
                anchors.verticalCenter: parent.verticalCenter
                glyph: row.glyph
                color: row.tone
            }
            Text {
                id: label
                anchors { left: icon.right; leftMargin: 12; verticalCenter: parent.verticalCenter }
                text: row.text
                color: row.tone
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
            }
            Text {
                id: detailText
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: row.detail
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
            }
        }
    }

    Choice {
        objectName: "menuPlay"
        visible: !titleMenu.seasonTab && !titleMenu.upcoming && !titleMenu.header
        glyph: "play_arrow"
        text: qsTrId("commonPlay")
        onTriggered: {
            if (titleMenu.target.play)
                titleMenu.target.play()
            else
                titleMenu.play(titleMenu.item, titleMenu.episode ? {season: titleMenu.episode.season, episode: titleMenu.episode.number} : null)
        }
    }
    Choice {
        objectName: "menuTrailer"
        // The page plays its own, less those found not to play here.
        visible: titleMenu.header ? !!titleMenu.target.trailer : !titleMenu.onPage && titleMenu.trailers.length > 0
        glyph: "movie"
        text: qsTrId("itemTrailer")
        onTriggered: {
            if (titleMenu.header) {
                titleMenu.target.trailer()
                return
            }
            const item = titleMenu.item
            titleMenu.trailer({
                urls: titleMenu.trailers,
                start: 0,
                play: qsTrId("commonPlay"),
                played: () => titleMenu.play(item, null),
                failed: () => {},
            }, item.title)
        }
    }
    Choice {
        objectName: "menuList"
        visible: !titleMenu.onPage
        usable: titleMenu.mine?.known ?? false
        glyph: titleMenu.mine?.inList ?? false ? "bookmark_filled" : "bookmark"
        text: titleMenu.mine?.inList ?? false ? qsTrId("menuRemoveFromList") : qsTrId("libraryAddToList")
        onTriggered: titleMenu.mine.toggle()
    }
    Choice {
        objectName: "menuWatched"
        readonly property bool seen: !!titleMenu.entry && titleMenu.entry.watched && titleMenu.entry.position === 0
        // A series as a whole: offered until it is caught up with.
        visible: !titleMenu.seasonTab && !titleMenu.upcoming
                 && (!!titleMenu.one || !titleMenu.ready || titleMenu.entries.length === 0 || !!titleMenu.about.progress.next)
        usable: titleMenu.ready
        glyph: seen ? "visibility_off" : "visibility"
        text: !titleMenu.one ? qsTrId("menuMarkSeriesWatched")
              : seen ? qsTrId("menuMarkUnwatched") : qsTrId("menuMarkWatched")
        onTriggered: {
            if (titleMenu.one)
                Viewing.mark(titleMenu.item.id, titleMenu.one.season, titleMenu.one.episode, !seen)
            else
                Viewing.markThrough(titleMenu.item.id)
        }
    }
    Choice {
        objectName: "menuWatchedUpTo"
        // An episode's card or a season's tab on the title's page; specials
        // are not part of the run.
        visible: titleMenu.onPage && (titleMenu.seasonTab ? titleMenu.target.season > 0 && (titleMenu.target.aired ?? 0) > 0
                                                : !!titleMenu.episode && titleMenu.episode.season > 0 && !titleMenu.upcoming)
        glyph: "visibility"
        text: qsTrId("menuMarkWatchedUpTo")
        onTriggered: {
            if (titleMenu.seasonTab)
                Viewing.markThrough(titleMenu.item.id, titleMenu.target.season, titleMenu.target.aired)
            else
                Viewing.markThrough(titleMenu.item.id, titleMenu.episode.season, titleMenu.episode.number)
        }
    }
    Choice {
        objectName: "menuForget"
        visible: titleMenu.series && titleMenu.entries.length > 0
        glyph: "visibility_off"
        text: qsTrId("menuMarkSeriesUnwatched")
        onTriggered: Viewing.forget(titleMenu.item.id)
    }
    Choice {
        objectName: "menuHide"
        visible: !!titleMenu.target.continuing
        glyph: "close"
        text: qsTrId("menuRemoveFromContinue")
        onTriggered: Viewing.hide(titleMenu.item.id)
    }
    Choice {
        objectName: "menuRate"
        visible: !titleMenu.seasonTab && !titleMenu.upcoming && (!titleMenu.onPage || !!titleMenu.episode)
        usable: titleMenu.mine?.known ?? false
        glyph: "star"
        text: titleMenu.rateText()
        detail: (titleMenu.mine?.score ?? 0) > 0 ? Words.count(titleMenu.mine.score) : ""
        onTriggered: {
            scorePicker.x = titleMenu.x
            scorePicker.y = titleMenu.y
            scorePicker.open()
        }
    }
    Choice {
        objectName: "menuDownload"
        // Nothing of it yet; one arriving is the downloads panel's.
        visible: titleMenu.seasonTab ? !!titleMenu.target.download && (titleMenu.target.aired ?? 0) > 0
                                : !!titleMenu.one && !titleMenu.upcoming && !titleMenu.download.id && !titleMenu.header
        glyph: "download"
        text: titleMenu.seasonTab ? qsTrId("menuDownloadSeason") : qsTrId("commonDownload")
        onTriggered: {
            if (titleMenu.seasonTab)
                titleMenu.target.download()
            else
                titleMenu.about.downloadSeason([{season: titleMenu.one.season, number: titleMenu.one.episode}])
        }
    }
    Choice {
        objectName: "menuDelete"
        visible: !!titleMenu.one && titleMenu.download.state === "done"
        glyph: "delete"
        danger: true
        text: qsTrId("menuDeleteDownload")
        onTriggered: Downloads.stop(titleMenu.download.id)
    }
    Choice {
        objectName: "menuLink"
        visible: (!titleMenu.onPage || titleMenu.header) && titleMenu.ready && titleMenu.about.link !== ""
        glyph: "link"
        text: qsTrId("menuCopyLink")
        onTriggered: {
            titleMenu.about.copyLink()
            titleMenu.say(qsTrId("itemLinkCopied"))
        }
    }
}
