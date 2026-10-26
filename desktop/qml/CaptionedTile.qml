import QtQuick
import Lumeo

// A poster with its name and a line under it, for a grid of titles to look
// through, where a poster alone may be missing or unfamiliar. The keyboard
// given to it goes to the poster.
FocusScope {
    id: slot

    required property var item
    // What the line under the name says.
    property string line
    // The viewer's own score after the line, as a star and a number; the
    // star is what says whose it is (decisions/library.md).
    property int score
    property var mark
    property real posterHeight: Math.round(width * 1.5)
    readonly property alias button: tile

    signal clicked()

    implicitWidth: 160
    height: posterHeight + 46
    // Over its neighbours while lifted, or the next one covers its shadow.
    z: tile.lifted ? 1 : 0

    PosterTile {
        id: tile
        objectName: slot.objectName + "-poster"
        focus: true
        width: parent.width
        height: slot.posterHeight
        item: slot.item
        mark: slot.mark
        onClicked: slot.clicked()
    }
    Column {
        y: slot.posterHeight + 8
        width: parent.width
        spacing: 2

        Text {
            width: parent.width
            text: slot.item.title
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textCard
            font.weight: Font.Medium
            elide: Text.ElideRight
        }
        Row {
            width: parent.width
            spacing: 8

            Text {
                width: Math.min(implicitWidth, parent.width - (stars.visible ? stars.width + 8 : 0))
                text: slot.line
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                elide: Text.ElideRight
            }
            Row {
                id: stars
                visible: slot.score > 0
                spacing: 3
                Glyph { anchors.verticalCenter: parent.verticalCenter; glyph: "star"; size: 13 }
                Text {
                    text: Words.count(slot.score)
                    color: Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textData
                }
            }
        }
    }
}
