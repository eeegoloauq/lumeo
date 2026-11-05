pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Qt.labs.qmlmodels
import Lumeo
import "format.js" as Format

// Search as a page under its field: the titles as the word is typed, the
// best match first and big, the rest as a grid with their names under them,
// since a poster alone may be missing or unfamiliar. An empty field offers
// the searches from before and what is popular.
ShellPage {
    id: page

    required property Search search

    // A title to open.
    signal open(var item)
    // Up from the top of the page: back to the field.
    signal up()

    readonly property real gap: 16
    readonly property real inner: width - 2 * Tokens.gutter
    readonly property int columns: Math.max(3, Math.floor((inner + gap) / (160 + gap)))
    readonly property real cell: Math.floor((inner - (columns - 1) * gap) / columns)
    readonly property real poster: Math.round(cell * 1.5)
    // The name and the year under each poster.
    readonly property real caption: 46
    // How many columns the best match spans; the posters beside it fill
    // the rest of its row.
    readonly property int span: columns >= 6 ? 3 : 2

    readonly property bool idle: search.status === Search.Idle
    readonly property bool found: search.status === Search.Ready && search.films + search.series > 0

    // Down from the field: into what the page shows.
    function enter() {
        if (found && grid.count > 0)
            return focusAt(0)
        if (idle && grid.head?.popular.item)
            return (grid.head.popular.item as ShelfRow)?.focusCard() ?? false
        return false
    }

    // A place may be off screen and not made yet: the view makes it first.
    function focusAt(place) {
        grid.positionViewAtIndex(place, GridView.Contain)
        const made = grid.itemAtIndex(place)
        const target = (made as Cell)?.button ?? made
        if (!target)
            return false
        target.forceActiveFocus(Qt.TabFocusReason)
        reveal(made)
        return true
    }

    // The arrows walk the grid as it is drawn: the best match is place 0,
    // and the places it covers beside it lead back to it.
    function move(place, across, down) {
        const title = at => at < search.lead ? 0 : at
        if (across !== 0) {
            const to = place === 0 && across > 0 ? search.lead : place + across
            return focusAt(title(Math.max(0, Math.min(grid.count - 1, to))))
        }
        const to = place + down * columns
        if (to < 0) {
            page.up()
            return true
        }
        return to < grid.count && focusAt(title(to))
    }

    // Clear of the bar floating over the page's top.
    function reveal(item) {
        const clearance = 90
        if (item.y - clearance < grid.contentY)
            grid.contentY = Math.max(grid.originY, item.y - clearance)
        else if (item.y + item.height + 24 > grid.contentY + grid.height)
            grid.contentY = item.y + item.height + 24 - grid.height
    }

    // The poster and its caption, one cell of the grid.
    component Cell: CaptionedTile {
        id: slot

        required property int index

        objectName: "result-" + item.id
        width: page.cell
        posterHeight: page.poster
        line: qsTrId("searchYearKind").arg(Format.years(item))
              .arg(item.kind === "series" ? qsTrId("commonSeries") : qsTrId("commonFilm"))
              .trim()
        markKey: item.id
        onClicked: page.open(item)
        onMenu: at => TitleActions.ask({item: item, source: button, x: at.x, y: at.y})
        button.Keys.onLeftPressed: page.move(slot.index, -1, 0)
        button.Keys.onRightPressed: page.move(slot.index, 1, 0)
        button.Keys.onUpPressed: page.move(slot.index, 0, -1)
        button.Keys.onDownPressed: page.move(slot.index, 0, 1)
    }

    scrolled: grid.contentY - grid.originY > 12

    Binding {
        target: page.search
        property: "lead"
        value: page.span
    }

    Loading {
        anchors.centerIn: parent
        waiting: page.search.status === Search.Searching
    }

    Trouble {
        objectName: "unanswered"
        anchors.centerIn: parent
        visible: page.search.status === Search.Failed
        title: qsTrId("searchCatalogueUnavailable")
        action: qsTrId("commonTryAgain")
        onActed: page.search.retry()
    }

    Trouble {
        objectName: "nothing"
        anchors.centerIn: parent
        visible: page.search.status === Search.Ready && !page.found
        title: qsTrId("searchNoResults").arg(page.search.answered)
        hint: qsTrId("searchProviderHint")
    }

    // The titles, made as they come into view; the searches from before,
    // what is popular and the kinds are its header and scroll with it.
    GridView {
        id: grid
        anchors.fill: parent
        visible: page.idle || page.found
        // The margins hold exactly the page's columns: a column is a cell
        // and the gap after it, and the last gap hangs into the right one.
        leftMargin: Tokens.gutter
        rightMargin: Tokens.gutter - page.gap
        bottomMargin: 56
        cellWidth: page.cell + page.gap
        cellHeight: page.poster + page.caption + page.gap
        boundsBehavior: Flickable.StopAtBounds
        model: page.search.titles
        // The arrows are the page's (move()): the view's own would stop on
        // the places the best match covers, and its current item scrolls
        // the page on arrival.
        keyNavigationEnabled: false
        currentIndex: -1
        // A page at its top stays there as its header grows: the view keeps
        // its place instead, which left the searches from before under the
        // bar when they came.
        property bool atTop: true
        onContentYChanged: atTop = contentY <= originY + 1
        onOriginYChanged: if (atTop) contentY = originY

        readonly property SearchHeader head: headerItem as SearchHeader
        header: SearchHeader {}

        delegate: DelegateChooser {
            role: "place"

            DelegateChoice {
                roleValue: "best"

                BestMatch {
                    id: bestMatch
                    objectName: "best"
                    width: page.span * page.cell + (page.span - 1) * page.gap
                    height: page.poster + page.caption
                    onClicked: page.open(item)
                    onMenu: at => TitleActions.ask({item: item, source: bestMatch, x: at.x, y: at.y})
                    Keys.onLeftPressed: page.move(0, -1, 0)
                    Keys.onRightPressed: page.move(0, 1, 0)
                    Keys.onUpPressed: page.move(0, 0, -1)
                    Keys.onDownPressed: page.move(0, 0, 1)
                }
            }
            DelegateChoice {
                roleValue: "gap"

                Item {}
            }
            DelegateChoice {
                roleValue: "title"

                Cell {}
            }
        }
    }

    WheelScroll { flickable: grid }

    // The view places its header at its left margin; the shelf under the
    // searches spans the page.
    component SearchHeader: Item {
        readonly property alias popular: popular

        width: page.inner
        height: column.height

        Column {
            id: column
            x: -grid.leftMargin
            width: page.width
            // The titles start under their kinds, closer to the bar than a heading.
            topPadding: page.idle ? 108 : 88
            spacing: 0

            // An empty field: the searches from before, each asked again with
            // a click and forgotten with its cross.
            Column {
                x: Tokens.gutter
                width: page.inner
                visible: page.idle && page.search.recent.length > 0
                spacing: 14
                bottomPadding: 40

                Row {
                    spacing: 16

                    Text {
                        anchors.baseline: forgetAll.baseline
                        text: qsTrId("searchRecent")
                        color: Tokens.text
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textShelf
                        font.weight: Font.DemiBold
                    }
                    AbstractButton {
                        id: forgetAll
                        objectName: "forgetAll"
                        focusPolicy: Qt.TabFocus
                        hoverEnabled: true
                        text: qsTrId("commonClear")
                        onClicked: page.search.forget("")
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        contentItem: Text {
                            text: forgetAll.text
                            color: forgetAll.hovered || forgetAll.visualFocus ? Tokens.text : Tokens.muted
                            font.family: Tokens.fontSans
                            font.pixelSize: Tokens.textCard
                            font.weight: Font.Medium
                        }
                        background: null
                    }
                }

                Flow {
                    width: parent.width
                    spacing: 8

                    Repeater {
                        model: page.search.recent

                        Rectangle {
                            id: chip

                            required property string modelData

                            width: words.implicitWidth + 16 + forget.width + 6
                            height: 36
                            radius: height / 2
                            color: words.hovered ? Tokens.floating : Tokens.raised
                            border.width: 1
                            border.color: words.visualFocus ? Theme.accent : Tokens.rim

                            AbstractButton {
                                id: words
                                objectName: "recent-" + chip.modelData
                                x: 16
                                height: parent.height
                                focusPolicy: Qt.TabFocus
                                hoverEnabled: true
                                text: chip.modelData
                                onClicked: page.search.query = chip.modelData
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                contentItem: Text {
                                    text: words.text
                                    color: Tokens.text
                                    font.family: Tokens.fontSans
                                    font.pixelSize: Tokens.textCard
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: null
                            }
                            IconButton {
                                id: forget
                                objectName: "forget-" + chip.modelData
                                anchors { right: parent.right; rightMargin: 5; verticalCenter: parent.verticalCenter }
                                width: 26
                                height: 26
                                glyph: "close"
                                glyphSize: 13
                                tone: Tokens.muted
                                tip: qsTrId("searchForget")
                                onClicked: page.search.forget(chip.modelData)
                            }
                        }
                    }
                }
            }

            Loader {
                id: popular
                width: parent.width
                active: page.idle && page.search.popular !== null
                // An unloaded Loader keeps its last item's height.
                visible: active

                sourceComponent: ShelfRow {
                    shelf: page.search.popular
                    onChosen: item => page.open(item)
                }
            }

            // Both kinds, or one: shown once there is something to choose
            // between.
            Row {
                x: Tokens.gutter
                visible: page.found
                spacing: 8
                bottomPadding: 24

                Repeater {
                    model: [
                        { kind: "", label: qsTrId("searchAll"), count: page.search.films + page.search.series },
                        { kind: "movie", label: qsTrId("searchFilms"), count: page.search.films },
                        { kind: "series", label: qsTrId("searchSeries"), count: page.search.series },
                    ]
                    PillTab {
                        required property var modelData
                        objectName: "kind-" + modelData.kind
                        text: modelData.label + "  " + modelData.count
                        lit: page.search.kind === modelData.kind
                        enabled: modelData.count > 0
                        onClicked: page.search.kind = modelData.kind
                    }
                }
            }
        }
    }
}
