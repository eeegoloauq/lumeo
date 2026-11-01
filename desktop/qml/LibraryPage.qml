pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo
import "format.js" as Format

// What the viewer keeps and has watched (decisions/library.md). My list is
// a grid of posters to look through, under a shelf of new episodes of the
// series followed; History is lines by the day they were watched, where
// what was watched is scored. The bar's lit tab names the page, so it has
// no heading of its own.
ShellPage {
    id: page

    // "list" or "history".
    property string section: "list"

    // A title to open, on the episode [at] names, {season, episode}, or
    // where watching goes on when null.
    signal open(var item, var at)

    readonly property real gap: 16
    readonly property real inner: width - 2 * Tokens.gutter
    readonly property int columns: Math.max(3, Math.floor((inner + gap) / (160 + gap)))
    readonly property real cell: Math.floor((inner - (columns - 1) * gap) / columns)
    readonly property var titles: list.titles
    // Back from a title opened here, which may have changed the list.
    property bool shown

    readonly property var orders: ({
        added: qsTrId("libraryRecentlyAdded"),
        title: qsTrId("librarySortTitle"),
        year: qsTrId("librarySortYear"),
        rating: qsTrId("librarySortRating"),
    })

    // How far into the list the grid shows: "all", "toWatch", "watching" or
    // "watched". A way of looking for the evening, so this page's only.
    property string stage: "all"

    readonly property var kinds: ({
        "": qsTrId("libraryKindBoth"),
        movie: qsTrId("libraryKindFilms"),
        series: qsTrId("libraryKindSeries"),
    })

    // The keyboard onto the grid's first title, from the shelves over it.
    function focusGrid() {
        if (grid.count === 0)
            return false
        grid.currentIndex = 0
        const tile = grid.currentItem as CaptionedTile
        tile.button.forceActiveFocus(Qt.TabFocusReason)
        return true
    }

    scrolled: section === "list" ? grid.contentY - grid.originY > 12 : lines.contentY - lines.originY > 12

    // History is read the first time it is shown: most visits to the
    // library never open it.
    onSectionChanged: if (section === "history") page.history.more()
    Component.onCompleted: if (section === "history") page.history.more()
    StackView.onActivated: {
        if (shown)
            list.load()
        shown = true
    }
    // Kept for its list and posters (Shell); the rest is a new page's. A new
    // History tells the core of a line still waiting for its undo, as one
    // going with its page did.
    StackView.onRemoved: {
        section = "list"
        stage = "all"
        grid.positionViewAtBeginning()
        const old = page.history
        page.history = historyModel.createObject(page) as History
        old.destroy()
    }

    MyList {
        id: list
        order: LocalSettings.listSort
        kind: LocalSettings.listKind
        stage: page.stage
    }

    // A title changed from its menu, here or on another page: the list and
    // the history are read again.
    Connections {
        target: TitleActions
        function onChanged() {
            list.load()
            if (!page.history.started)
                return
            const old = page.history
            page.history = historyModel.createObject(page) as History
            old.destroy()
            page.history.more()
        }
    }

    property History history: historyModel.createObject(page) as History
    Component {
        id: historyModel
        History {
            onRefused: what => toast.say({
                rate: qsTrId("libraryRatingNotSaved"),
                clear: qsTrId("libraryRatingNotRemoved"),
                remove: qsTrId("libraryHistoryRemoveFailed"),
            }[what])
        }
    }

    // The two places in the library, and the order of the list.
    component Places: Item {
        width: page.width
        height: 96 + 34 + 24

        Row {
            x: Tokens.gutter
            y: 96
            spacing: 8

            PillTab {
                objectName: "place-list"
                text: qsTrId("libraryMyList")
                lit: page.section === "list"
                onClicked: page.section = "list"
            }
            PillTab {
                objectName: "place-history"
                text: qsTrId("libraryHistory")
                lit: page.section === "history"
                onClicked: page.section = "history"
            }
        }

        AbstractButton {
            id: sort
            objectName: "sort"
            anchors { right: parent.right; rightMargin: Tokens.gutter }
            y: 96
            visible: page.section === "list"
            implicitHeight: 34
            implicitWidth: sortRow.implicitWidth + 20
            focusPolicy: Qt.TabFocus
            hoverEnabled: true
            onClicked: orders.opened ? orders.close() : orders.open()
            HoverHandler { cursorShape: Qt.PointingHandCursor }

            background: Rectangle {
                radius: height / 2
                color: sort.down || sort.hovered ? Tokens.hover : "transparent"
                border.width: sort.visualFocus ? 2 : 0
                border.color: Theme.accent
            }
            contentItem: Row {
                id: sortRow
                leftPadding: 12
                spacing: 2
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: LocalSettings.listKind === "" ? qsTrId("librarySort").arg(page.orders[LocalSettings.listSort])
                      : qsTrId("librarySortKind").arg(page.orders[LocalSettings.listSort]).arg(page.kinds[LocalSettings.listKind])
                    color: Tokens.dim
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textCard
                    font.weight: Font.Medium
                }
                Glyph { anchors.verticalCenter: parent.verticalCenter; glyph: "arrow_drop_down"; size: 20; color: Tokens.dim }
            }

            Menu {
                id: orders
                objectName: "orders"
                y: sort.height + 6
                x: sort.width - width
                padding: 6
                background: Rectangle {
                    implicitWidth: 220
                    radius: Tokens.radiusFloating
                    color: Qt.alpha(Tokens.floating, 0.97)
                    border.color: Tokens.rim
                }

                Repeater {
                    model: ["added", "title", "year", "rating"]
                    Choice {
                        required property string modelData
                        objectName: "order-" + modelData
                        text: page.orders[modelData]
                        chosen: LocalSettings.listSort === modelData
                        onTriggered: LocalSettings.listSort = modelData
                    }
                }
                // Which kinds are shown, kept on this machine as the order is.
                MenuSeparator {
                    contentItem: Rectangle { implicitHeight: 1; color: Tokens.line }
                }
                Repeater {
                    model: ["", "movie", "series"]
                    Choice {
                        required property string modelData
                        objectName: "kind-" + (modelData || "both")
                        text: page.kinds[modelData]
                        chosen: LocalSettings.listKind === modelData
                        onTriggered: LocalSettings.listKind = modelData
                    }
                }
            }
        }
    }

    // A row of the sort menu, checked when it is the one in use.
    component Choice: MenuItem {
        id: choice
        property bool chosen
        implicitHeight: 36
        leftPadding: 10
        background: Rectangle {
            radius: Tokens.radiusControl
            color: choice.highlighted ? Tokens.hover : "transparent"
        }
        contentItem: Row {
            spacing: 10
            Item {
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
                Glyph { visible: choice.chosen; glyph: "check" }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: choice.text
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
            }
        }
    }

    component Heading: Text {
        x: Tokens.gutter
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textShelf
        font.weight: Font.DemiBold
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.textShelf * 1.25
    }

    // The titles as posters, made as they come into view; the places, the
    // shelves of followed series and the stages are its header and scroll
    // with it. The arrows are the grid's own, up from its first row to the
    // shelf over it.
    GridView {
        id: grid
        objectName: "myList"
        anchors.fill: parent
        visible: page.section === "list"
        // The margins hold exactly the page's columns: a column is a cell
        // and the gap after it, and the last gap hangs into the right one.
        leftMargin: Tokens.gutter
        rightMargin: Tokens.gutter - page.gap
        bottomMargin: 56
        cellWidth: page.cell + page.gap
        cellHeight: Math.round(page.cell * 1.5) + 46 + page.gap
        boundsBehavior: Flickable.StopAtBounds
        model: list.status === MyList.Ready ? page.titles : []
        // No title is current until the keyboard comes: the view scrolls to
        // its current one, which sent the page past its shelves on arrival.
        currentIndex: -1
        onModelChanged: if (!activeFocus) currentIndex = -1
        // A page at its top stays there as its header grows: the view keeps
        // its place instead, which left the shelves that come with the list
        // scrolled under the bar.
        property bool atTop: true
        onContentYChanged: atTop = contentY <= originY + 1
        onOriginYChanged: if (atTop) contentY = originY
        Keys.priority: Keys.AfterItem
        Keys.onUpPressed: event => {
            event.accepted = (head.comingUp.visible ? head.comingUp : head.fresh.visible ? head.fresh : null)?.focusCard(0) ?? false
        }
        // The keyboard's tile in the ring, and clear of the bar floating
        // over the page's top. The view hands its current item the focus
        // without saying it was the keyboard's, which the ring waits for.
        onCurrentIndexChanged: Qt.callLater(() => {
            const tile = currentItem as CaptionedTile
            if (!tile || !activeFocus)
                return
            tile.button.focusReason = Qt.TabFocusReason
            if (tile.y - 90 < contentY)
                contentY = Math.max(originY, tile.y - 90)
        })

        WheelScroll { flickable: grid }

        readonly property ListHeader head: headerItem as ListHeader
        header: ListHeader {}

        delegate: CaptionedTile {
            required property int index
            required property var modelData
            objectName: "listed-" + modelData.item.id
            width: page.cell
            item: modelData.item
            line: Words.listedCaption(modelData)
            score: modelData.rating ?? 0
            mark: Downloads.marks[modelData.item.id]
            onClicked: page.open(modelData.item, null)
            onMenu: at => TitleActions.ask({item: modelData.item, source: button, x: at.x, y: at.y})
            // Tab or the pointer can land on any title: the arrows go on
            // from there.
            onActiveFocusChanged: if (activeFocus) grid.currentIndex = index
        }
    }

    component ListHeader: Item {
        readonly property alias fresh: fresh
        readonly property alias comingUp: comingUp

        width: page.inner
        height: column.height

        Column {
            id: column
            x: -grid.leftMargin
            width: page.width
            bottomPadding: 4

            Places {}

            Loading {
                x: (parent.width - width) / 2
                waiting: list.status === MyList.Loading
            }

            Trouble {
                x: Tokens.gutter
                visible: list.status === MyList.Failed
                title: qsTrId("libraryListLoadFailed")
                hint: qsTrId("libraryListNoAnswer")
                detail: list.error
                action: qsTrId("commonTryAgain")
                onActed: list.load()
            }

            // The followed series with something new, on the first new
            // episode; then those with an episode dated ahead, on the soonest.
            SeriesShelf {
                id: fresh
                objectName: "fresh"
                title: qsTrId("libraryNewEpisodes")
                model: list.status === MyList.Ready ? list.fresh : []
                cell: page.cell
                gap: page.gap
                onChosen: (item, at) => page.open(item, at)
                caption: found => Words.newEpisodeCaption(found)
                onDown: (comingUp.visible ? comingUp : null)?.focusCard(0) ?? page.focusGrid()
            }

            SeriesShelf {
                id: comingUp
                objectName: "comingUp"
                title: qsTrId("libraryComingUp")
                model: list.status === MyList.Ready ? list.comingUp : []
                cell: page.cell
                gap: page.gap
                onChosen: (item, at) => page.open(item, at)
                caption: found => Words.comingUpCaption(found)
                onUp: if (fresh.visible) fresh.focusCard(0)
                onDown: page.focusGrid()
            }

            Heading {
                visible: (fresh.visible || comingUp.visible) && list.total > 0
                text: qsTrId("libraryMyList")
                bottomPadding: 14
            }

            Trouble {
                objectName: "listEmpty"
                x: Tokens.gutter
                visible: list.status === MyList.Ready && list.total === 0
                title: qsTrId("libraryListEmpty")
                hint: qsTrId("libraryListEmptyHint")
            }

            // How far into the list: To watch is the planned list, nothing
            // of it played.
            Row {
                x: Tokens.gutter
                visible: list.status === MyList.Ready && list.total > 0
                spacing: 8
                bottomPadding: 20

                Repeater {
                    model: [
                        { stage: "all", label: qsTrId("libraryStageAll") },
                        { stage: "toWatch", label: qsTrId("libraryStageToWatch") },
                        { stage: "watching", label: qsTrId("libraryStageWatching") },
                        { stage: "watched", label: qsTrId("libraryStageWatched") },
                    ]
                    PillTab {
                        required property var modelData
                        objectName: "stage-" + modelData.stage
                        text: modelData.label
                        lit: page.stage === modelData.stage
                        onClicked: page.stage = modelData.stage
                    }
                }
            }

            Text {
                objectName: "stageEmpty"
                x: Tokens.gutter
                visible: list.status === MyList.Ready && list.total > 0 && page.titles.length === 0
                text: qsTrId("libraryStageEmpty")
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
            }
        }
    }

    ListView {
        id: lines
        objectName: "history"
        anchors.fill: parent
        visible: page.section === "history"
        model: page.history
        boundsBehavior: Flickable.StopAtBounds
        // The rows pass the keyboard along themselves.
        keyNavigationEnabled: false

        // The next page as the end comes near, the way a shelf pages.
        function nearEnd() {
            if (visible && contentHeight - contentY - height < 600)
                page.history.more()
        }
        onContentYChanged: nearEnd()
        onCountChanged: nearEnd()
        onVisibleChanged: nearEnd()

        function step(index) {
            if (index < 0 || index >= count)
                return
            positionViewAtIndex(index, ListView.Contain)
            itemAtIndex(index)?.forceActiveFocus(Qt.TabFocusReason)
        }

        WheelScroll { flickable: lines }

        header: Column {
            width: lines.width

            Places {}

            Loading {
                x: (parent.width - width) / 2
                waiting: lines.count === 0 && !page.history.error && (page.history.loading || !page.history.started)
            }

            Trouble {
                x: Tokens.gutter
                visible: lines.count === 0 && page.history.error !== ""
                title: qsTrId("libraryHistoryLoadFailed")
                hint: qsTrId("libraryHistoryNoAnswer")
                detail: page.history.error
                action: qsTrId("commonTryAgain")
                onActed: page.history.retry()
            }

            Trouble {
                objectName: "historyEmpty"
                x: Tokens.gutter
                visible: lines.count === 0 && page.history.started && !page.history.loading && page.history.error === ""
                         && !page.history.removing
                title: qsTrId("libraryHistoryEmpty")
                hint: qsTrId("libraryHistoryEmptyHint")
            }
        }

        section.property: "day"
        section.delegate: Text {
            required property string section
            x: Tokens.gutter
            width: lines.width - 2 * Tokens.gutter
            topPadding: 24
            bottomPadding: 6
            text: Words.dayLabel(section)
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textMeta
            font.weight: Font.DemiBold
        }

        // A line of the list, the full width of the view, which places its
        // delegates at the left edge.
        delegate: FocusScope {
            id: slot

            required property int index
            required property var item
            required property var entry
            required property var episode
            required property int rating

            readonly property bool series: item.kind === "series"

            objectName: "line-" + item.id + "/" + entry.season + "/" + entry.episode
            width: lines.width
            height: 92

            AbstractButton {
                id: row

                readonly property bool under: hovered || activeFocus || score.activeFocus || cross.activeFocus

                x: Tokens.gutter - 6
                width: Math.min(860, lines.width - 2 * Tokens.gutter + 12)
                height: parent.height
                focus: true
                focusPolicy: Qt.TabFocus
                hoverEnabled: true
                Accessible.name: title.text
                onClicked: page.open(slot.item, slot.series ? { season: slot.entry.season, episode: slot.entry.episode } : null)
                // The title menu, about what the line is: the episode for a
                // series, which is scored from here.
                function menu(at) {
                    TitleActions.ask({
                        item: slot.item, history: true, source: row, x: at.x, y: at.y,
                        episode: !slot.series ? null : slot.episode ?? {season: slot.entry.season, number: slot.entry.episode},
                    })
                }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: point => row.menu(point.position) }
                Keys.onMenuPressed: menu(Qt.point(width / 2, height / 2))
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier) {
                        menu(Qt.point(width / 2, height / 2))
                        event.accepted = true
                    }
                }
                Keys.onUpPressed: lines.step(slot.index - 1)
                Keys.onDownPressed: lines.step(slot.index + 1)
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                background: Rectangle {
                    radius: Tokens.radiusControl
                    color: row.hovered ? Tokens.hover : "transparent"
                    border.width: row.visualFocus ? 2 : 0
                    border.color: Theme.accent
                }

                contentItem: Item {
                    // An episode's still under the season strip's spoiler rule;
                    // a film's backdrop.
                    Item {
                        id: picture
                        x: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 128
                        height: 72

                        readonly property real share: slot.entry.duration > 0 && slot.entry.position > 0
                                                      && slot.entry.position < slot.entry.duration
                                                      ? slot.entry.position / slot.entry.duration : 0

                        Loader {
                            anchors.fill: parent
                            active: slot.series
                            sourceComponent: EpisodeStill {
                                episode: slot.episode ?? { season: slot.entry.season, number: slot.entry.episode }
                                stills: Preferences.current.episodeArtwork ?? "show"
                                watched: slot.entry.watched
                                bar: picture.share
                                frame: EpisodeFrames.known[slot.item.id + "/" + slot.entry.season + "/" + slot.entry.episode] ?? ""
                            }
                        }
                        Rectangle {
                            anchors.fill: parent
                            visible: !slot.series
                            color: Tokens.surface

                            Image {
                                anchors.fill: parent
                                source: Format.art(slot.item.background ?? "")
                                sourceSize.width: 141
                                fillMode: Image.PreserveAspectCrop
                            }
                            WatchBar { share: picture.share }
                        }
                    }

                    Column {
                        anchors { left: picture.right; leftMargin: 14; right: score.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        spacing: 3

                        Text {
                            id: title
                            width: parent.width
                            text: Words.viewingTitle(slot.item, slot.entry, slot.episode)
                            color: Tokens.text
                            font.family: Tokens.fontSans
                            font.pixelSize: Tokens.textCard
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        Text {
                            objectName: "state"
                            text: Words.viewingState(slot.entry)
                            color: Tokens.muted
                            font.family: Tokens.fontSans
                            font.pixelSize: Tokens.textData
                        }
                    }

                    // The score of what the line is about: the episode for a
                    // series, the film otherwise; the title itself is scored on
                    // its page.
                    RatingButton {
                        id: score
                        objectName: "score"
                        anchors { right: cross.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                        score: slot.rating
                        onRated: n => page.history.rate(slot.index, n)
                        onCleared: page.history.rate(slot.index, 0)
                    }

                    // Shown under the pointer and to the keyboard, which can
                    // always reach it.
                    IconButton {
                        id: cross
                        objectName: "remove"
                        anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                        opacity: row.under ? 1 : 0
                        glyph: "close"
                        tone: Tokens.dim
                        tip: qsTrId("libraryRemoveFromHistory")
                        onClicked: page.history.remove(slot.index)
                    }
                }
            }
        }

        footer: Item {
            width: lines.width
            height: 56 + (more.visible || failed.visible ? 48 : 0)

            Loading {
                id: more
                anchors.horizontalCenter: parent.horizontalCenter
                y: 16
                width: 24
                height: 24
                waiting: page.history.loading && lines.count > 0
            }

            Row {
                id: failed
                x: Tokens.gutter
                y: 16
                visible: lines.count > 0 && page.history.error !== ""
                spacing: 12

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTrId("libraryMoreLoadFailed")
                    color: Tokens.muted
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textData
                }
                QuietButton {
                    implicitHeight: 36
                    text: qsTrId("commonTryAgain")
                    onClicked: page.history.retry()
                }
            }
        }
    }

    // A shelf of series over My list, one poster each, on the episode it
    // opens onto.
    component SeriesShelf: Column {
        id: shelf

        property string title
        property alias model: strip.model
        // What the poster's line says of one of [model].
        property var caption
        property real cell
        property real gap
        signal up()
        signal down()
        signal chosen(var item, var at)

        function focusCard(index) {
            return strip.focusCard(index)
        }

        width: parent.width
        visible: strip.count > 0
        spacing: 14
        bottomPadding: 34

        Heading { text: shelf.title }

        Strip {
            id: strip
            width: parent.width
            // The grid's columns, and room under the captions for the lift
            // on hover.
            height: Math.round(shelf.cell * 1.5) + 46 + 6
            spacing: shelf.gap

            delegate: CaptionedTile {
                required property int index
                required property var modelData
                objectName: shelf.objectName + "-" + modelData.item.id
                width: shelf.cell
                item: modelData.item
                line: shelf.caption(modelData)
                mark: Downloads.marks[modelData.item.id + "/" + modelData.episode.season + "/" + modelData.episode.number]
                onClicked: shelf.chosen(modelData.item, { season: modelData.episode.season, episode: modelData.episode.number })
                onMenu: at => TitleActions.ask({item: modelData.item, episode: modelData.episode, source: button,
                                                x: at.x, y: at.y})
                onActiveFocusChanged: if (activeFocus) strip.focused = index
                button.Keys.onUpPressed: shelf.up()
                button.Keys.onDownPressed: shelf.down()
            }
        }
    }

    // A line taken out, with the way to bring it back while the core has
    // not been told; or what the core refused.
    Toast {
        id: toast
        held: page.history.removing
        text: page.history.removing ? qsTrId("libraryRemovedFromHistory") : said
        action: page.history.removing ? qsTrId("commonUndo") : ""
        onActed: page.history.undo()
    }

    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: page.visible && page.history.removing
        onActivated: page.history.undo()
    }
}
