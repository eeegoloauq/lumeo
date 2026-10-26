pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
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

    readonly property var results: search.results
    readonly property bool idle: search.status === Search.Idle
    readonly property bool found: search.status === Search.Ready && search.films + search.series > 0

    // Down from the field: into what the page shows.
    function enter() {
        if (found && results.length > 0)
            return focusAt(0)
        if (idle && popular.item)
            return (popular.item as ShelfRow)?.focusCard() ?? false
        return false
    }

    function focusAt(index) {
        const target = index === 0 ? best.item : (tiles.itemAt(index - 1) as Cell)?.button
        if (!target)
            return false
        target.forceActiveFocus(Qt.TabFocusReason)
        reveal(target)
        return true
    }

    // The arrows walk the grid as it is drawn: the best match takes the
    // first [span] places of the first row.
    function move(index, across, down) {
        if (across !== 0)
            return focusAt(Math.max(0, Math.min(results.length - 1, index + across)))
        const place = (index === 0 ? 0 : index + span - 1) + down * columns
        if (place < 0) {
            page.up()
            return true
        }
        const at = place < span ? 0 : place - span + 1
        return at < results.length && focusAt(at)
    }

    function reveal(item) {
        const top = item.mapToItem(column, 0, 0).y
        const clearance = 90
        if (top - clearance < flick.contentY)
            flick.contentY = Math.max(0, top - clearance)
        else if (top + item.height + 24 > flick.contentY + flick.height)
            flick.contentY = top + item.height + 24 - flick.height
    }

    // The poster and its caption, one cell of the grid.
    component Cell: Item {
        id: slot

        required property int index
        required property var modelData
        readonly property alias button: tile

        width: page.cell
        height: page.poster + page.caption
        // Over its neighbours while lifted, or the next one covers its shadow.
        z: tile.lifted ? 1 : 0

        PosterTile {
            id: tile
            objectName: "result-" + slot.modelData.id
            width: parent.width
            height: page.poster
            item: slot.modelData
            mark: Downloads.marks[slot.modelData.id]
            onClicked: page.open(slot.modelData)
            Keys.onLeftPressed: page.move(slot.index + 1, -1, 0)
            Keys.onRightPressed: page.move(slot.index + 1, 1, 0)
            Keys.onUpPressed: page.move(slot.index + 1, 0, -1)
            Keys.onDownPressed: page.move(slot.index + 1, 0, 1)
        }
        Column {
            y: page.poster + 8
            width: parent.width
            spacing: 2

            Text {
                width: parent.width
                text: slot.modelData.title
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: qsTrId("searchYearKind").arg(Format.years(slot.modelData))
                      .arg(slot.modelData.kind === "series" ? qsTrId("commonSeries") : qsTrId("commonFilm"))
                      .trim()
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                elide: Text.ElideRight
            }
        }
    }

    scrolled: flick.contentY > 12

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

    Flickable {
        id: flick
        anchors.fill: parent
        visible: page.idle || page.found
        contentHeight: column.height
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { flickable: flick }

        Column {
            id: column
            width: flick.width
            // The titles start under their kinds, closer to the bar than a heading.
            topPadding: page.idle ? 108 : 88
            bottomPadding: 56
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

            Flow {
                x: Tokens.gutter
                width: page.inner
                visible: page.found
                spacing: page.gap

                Loader {
                    id: best
                    width: page.span * page.cell + (page.span - 1) * page.gap
                    height: page.poster + page.caption
                    active: page.found && page.results.length > 0

                    sourceComponent: BestMatch {
                        objectName: "best"
                        item: page.results[0]
                        onClicked: page.open(item)
                        Keys.onLeftPressed: page.move(0, -1, 0)
                        Keys.onRightPressed: page.move(0, 1, 0)
                        Keys.onUpPressed: page.move(0, 0, -1)
                        Keys.onDownPressed: page.move(0, 0, 1)
                    }
                }

                Repeater {
                    id: tiles
                    model: page.found ? page.results.slice(1) : []

                    Cell {}
                }
            }
        }
    }
}
