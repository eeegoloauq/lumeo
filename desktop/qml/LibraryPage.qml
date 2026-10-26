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

    function focusTile(index) {
        const tile = tiles.itemAt(index) as CaptionedTile
        if (!tile)
            return false
        tile.button.forceActiveFocus(Qt.TabFocusReason)
        const top = tile.mapToItem(column, 0, 0).y
        if (top - 90 < flick.contentY)
            flick.contentY = Math.max(0, top - 90)
        else if (top + tile.height + 24 > flick.contentY + flick.height)
            flick.contentY = top + tile.height + 24 - flick.height
        return true
    }

    // The arrows walk the grid as it is drawn; up from its first row is the
    // shelf over it, when there is one.
    function move(index, by) {
        const to = index + by
        if (to < 0 && Math.abs(by) > 1)
            return fresh.visible && freshStrip.focusCard(0)
        return to >= 0 && to < titles.length && focusTile(to)
    }

    scrolled: section === "list" ? flick.contentY > 12 : lines.contentY - lines.originY > 12

    // History is read the first time it is shown: most visits to the
    // library never open it.
    onSectionChanged: if (section === "history") history.more()
    Component.onCompleted: if (section === "history") history.more()
    StackView.onActivated: {
        if (shown)
            list.load()
        shown = true
    }

    MyList {
        id: list
        order: LocalSettings.listSort
    }

    History {
        id: history
        onRefused: what => toast.say({
            rate: qsTrId("libraryRatingNotSaved"),
            clear: qsTrId("libraryRatingNotRemoved"),
            remove: qsTrId("libraryHistoryRemoveFailed"),
        }[what])
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
                    text: qsTrId("librarySort").arg(page.orders[LocalSettings.listSort])
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
                    MenuItem {
                        id: order
                        required property string modelData
                        objectName: "order-" + modelData
                        text: page.orders[modelData]
                        onTriggered: LocalSettings.listSort = modelData
                        implicitHeight: 36
                        leftPadding: 10
                        background: Rectangle {
                            radius: Tokens.radiusControl
                            color: order.highlighted ? Tokens.hover : "transparent"
                        }
                        contentItem: Row {
                            spacing: 10
                            Item {
                                width: 18
                                height: 18
                                anchors.verticalCenter: parent.verticalCenter
                                Glyph { visible: LocalSettings.listSort === order.modelData; glyph: "check" }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: order.text
                                color: Tokens.text
                                font.family: Tokens.fontSans
                                font.pixelSize: Tokens.textCard
                            }
                        }
                    }
                }
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

    Flickable {
        id: flick
        objectName: "myList"
        anchors.fill: parent
        visible: page.section === "list"
        contentHeight: column.height
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { flickable: flick }

        Column {
            id: column
            width: flick.width
            bottomPadding: 56

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

            // The followed series with something new; one poster each, on
            // the first new episode, which it opens onto.
            Column {
                id: fresh
                objectName: "fresh"
                width: parent.width
                visible: list.status === MyList.Ready && list.fresh.length > 0
                spacing: 14
                bottomPadding: 34

                Heading { text: qsTrId("libraryNewEpisodes") }

                Strip {
                    id: freshStrip
                    width: parent.width
                    // The grid's columns, and room under the captions for
                    // the lift on hover.
                    height: Math.round(page.cell * 1.5) + 46 + 6
                    spacing: page.gap
                    model: list.fresh

                    delegate: CaptionedTile {
                        required property int index
                        required property var modelData
                        objectName: "fresh-" + modelData.item.id
                        width: page.cell
                        item: modelData.item
                        line: Words.newEpisodeCaption(modelData)
                        mark: Downloads.marks[modelData.item.id + "/" + modelData.episode.season + "/" + modelData.episode.number]
                        onClicked: page.open(modelData.item, { season: modelData.episode.season, episode: modelData.episode.number })
                        onActiveFocusChanged: if (activeFocus) freshStrip.focused = index
                        button.Keys.onDownPressed: page.focusTile(0)
                    }
                }
            }

            Heading {
                visible: fresh.visible && page.titles.length > 0
                text: qsTrId("libraryMyList")
                bottomPadding: 14
            }

            Trouble {
                objectName: "listEmpty"
                x: Tokens.gutter
                visible: list.status === MyList.Ready && page.titles.length === 0
                title: qsTrId("libraryListEmpty")
                hint: qsTrId("libraryListEmptyHint")
            }

            Flow {
                x: Tokens.gutter
                width: page.inner
                spacing: page.gap

                Repeater {
                    id: tiles
                    model: list.status === MyList.Ready ? page.titles : []

                    CaptionedTile {
                        required property int index
                        required property var modelData
                        objectName: "listed-" + modelData.item.id
                        width: page.cell
                        item: modelData.item
                        line: Words.listedCaption(modelData)
                        score: modelData.rating ?? 0
                        mark: Downloads.marks[modelData.item.id]
                        onClicked: page.open(modelData.item, null)
                        button.Keys.onLeftPressed: page.move(index, -1)
                        button.Keys.onRightPressed: page.move(index, 1)
                        button.Keys.onUpPressed: page.move(index, -page.columns)
                        button.Keys.onDownPressed: page.move(index, page.columns)
                    }
                }
            }
        }
    }

    ListView {
        id: lines
        objectName: "history"
        anchors.fill: parent
        visible: page.section === "history"
        model: history
        boundsBehavior: Flickable.StopAtBounds
        // The rows pass the keyboard along themselves.
        keyNavigationEnabled: false

        // The next page as the end comes near, the way a shelf pages.
        function nearEnd() {
            if (visible && contentHeight - contentY - height < 600)
                history.more()
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
                waiting: lines.count === 0 && !history.error && (history.loading || !history.started)
            }

            Trouble {
                x: Tokens.gutter
                visible: lines.count === 0 && history.error !== ""
                title: qsTrId("libraryHistoryLoadFailed")
                hint: qsTrId("libraryHistoryNoAnswer")
                detail: history.error
                action: qsTrId("commonTryAgain")
                onActed: history.retry()
            }

            Trouble {
                objectName: "historyEmpty"
                x: Tokens.gutter
                visible: lines.count === 0 && history.started && !history.loading && history.error === ""
                         && !history.removing
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
                        onRated: n => history.rate(slot.index, n)
                        onCleared: history.rate(slot.index, 0)
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
                        onClicked: history.remove(slot.index)
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
                waiting: history.loading && lines.count > 0
            }

            Row {
                id: failed
                x: Tokens.gutter
                y: 16
                visible: lines.count > 0 && history.error !== ""
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
                    onClicked: history.retry()
                }
            }
        }
    }

    // A line taken out, with the way to bring it back while the core has
    // not been told; or what the core refused.
    Toast {
        id: toast
        held: history.removing
        text: history.removing ? qsTrId("libraryRemovedFromHistory") : said
        action: history.removing ? qsTrId("commonUndo") : ""
        onActed: history.undo()
    }

    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: page.visible && history.removing
        onActivated: history.undo()
    }
}
