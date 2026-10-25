pragma ComponentBehavior: Bound

import QtQuick
import Lumeo

// A shelf: its name over its row of posters. It asks for its first page
// once it is built, and for the next while a screen of posters is left.
Column {
    id: row

    required property Shelf shelf

    // A card was chosen: a title to open, or for watch progress one to play.
    signal chosen(var item)

    readonly property bool progress: shelf.catalog === "continue"
    // One of its cards has the keyboard.
    readonly property bool holdsKeys: strip.activeFocus

    // The keyboard arriving from another row lands on the first card shown.
    function focusCard() {
        return strip.focusCard(strip.firstShown())
    }

    // Named when drawn, so a change of language renames what is on screen.
    function label() {
        if (progress)
            return qsTrId("homeContinueWatching")
        if (shelf.genre !== "")
            return shelf.kind === "series" ? qsTrId("homeGenreSeries").arg(shelf.genre)
                                           : qsTrId("homeGenreFilms").arg(shelf.genre)
        switch (shelf.kind + "/" + shelf.catalog) {
        case "movie/top": return qsTrId("homePopularFilms")
        case "series/top": return qsTrId("homePopularSeries")
        case "movie/imdbRating": return qsTrId("homeHighestRated")
        case "movie/year": return qsTrId("homeOutRecently")
        case "series/imdbRating": return qsTrId("homeHighestRatedSeries")
        }
        return shelf.catalog
    }

    objectName: "shelf-" + shelf.kind + "/" + shelf.catalog + "/" + shelf.genre
    // A genre nobody has titles for is not a shelf.
    visible: !shelf.empty
    height: visible ? implicitHeight : 0
    spacing: 14

    Component.onCompleted: if (strip.count === 0) shelf.more()

    Text {
        x: Tokens.gutter
        text: row.label()
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textShelf
        font.weight: Font.DemiBold
        font.letterSpacing: -0.1
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.textShelf * 1.25
    }

    // Room under the posters for the lift on hover.
    Item {
        width: row.width
        height: 246

        Strip {
            id: strip
            objectName: "strip"
            anchors.fill: parent
            model: row.shelf
            onContentXChanged: {
                if (originX + contentWidth - contentX - width < 900)
                    row.shelf.more()
            }

            delegate: PosterTile {
                required property int index
                required item
                required property var season
                required property var episode
                required watched

                mark: row.progress ? Downloads.marks[item.id + "/" + season + "/" + episode]
                                   : Downloads.marks[item.id]
                onClicked: row.chosen(item)
                onActiveFocusChanged: if (activeFocus) strip.focused = index
            }
        }

        // A shelf that has not arrived yet holds its own space, so nothing
        // under it jumps when it does.
        Row {
            x: Tokens.gutter
            visible: strip.count === 0
            spacing: 8
            Repeater {
                model: 8
                Rectangle { width: 160; height: 240; color: Tokens.surface }
            }
        }
    }
}
