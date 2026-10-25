import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Lumeo
import "format.js" as Format

// One title in a shelf. No caption underneath, so a row reads as a shelf;
// the year and rating appear on hover, and the card lifts rather than
// grows, so its neighbours stay where they were (decisions/interface.md).
AbstractButton {
    id: tile

    required property var item
    // One of Downloads.marks, or undefined.
    property var mark
    // The share watched, for a card of watch progress; undefined on others.
    property var watched

    readonly property bool lifted: hovered || visualFocus

    implicitWidth: 160
    implicitHeight: 240
    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    // Over its neighbours while lifted, or the next one covers its shadow.
    z: lifted ? 1 : 0
    Accessible.name: item.title

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: null
    contentItem: Item {
        scale: tile.lifted ? 1.05 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
        layer.enabled: tile.lifted
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#b3000000"
            shadowBlur: 0.7
            shadowVerticalOffset: 8
            shadowHorizontalOffset: 0
        }

        // Never a hole in the shelf: until the artwork arrives, and if it
        // never does, the tile is a card with the title on it.
        Rectangle {
            anchors.fill: parent
            visible: poster.status !== Image.Ready
            color: Tokens.raised

            Text {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                text: tile.item.title
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                font.weight: Font.DemiBold
                lineHeightMode: Text.FixedHeight
                lineHeight: Tokens.textCard * 1.25
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }
        }

        Image {
            id: poster
            anchors.fill: parent
            source: Format.art(tile.item.poster)
            // Decoded at the size it is drawn, with a little to spare for the lift.
            sourceSize.width: 176
            fillMode: Image.PreserveAspectCrop
        }

        // What the artwork cannot say; it fades, since a hard cut on every
        // pointer crossing flickers.
        Rectangle {
            anchors.fill: parent
            opacity: tile.lifted ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
            // Dark at the foot so type has a ground, gone by half way up.
            gradient: Gradient {
                GradientStop { position: 0.38; color: Qt.alpha(Tokens.page, 0) }
                GradientStop { position: 0.72; color: Qt.alpha(Tokens.page, 0.8) }
                GradientStop { position: 1; color: Qt.alpha(Tokens.page, 0.95) }
            }

            Column {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
                spacing: 6

                // A poster's lettering is a texture at this size; a card
                // with no artwork already prints the name.
                Text {
                    width: parent.width
                    visible: poster.status === Image.Ready
                    text: tile.item.title
                    color: Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textCard
                    font.weight: Font.DemiBold
                    lineHeightMode: Text.FixedHeight
                    lineHeight: Tokens.textCard * 1.25
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Item {
                    width: parent.width
                    height: years.implicitHeight
                    visible: years.text !== "" || rating.text !== ""

                    Text {
                        id: years
                        text: Format.years(tile.item)
                        color: Tokens.dim
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textData
                    }
                    Text {
                        id: rating
                        anchors.right: parent.right
                        text: Format.rating(tile.item.imdbRating, Qt.locale())
                        color: Tokens.text
                        font.family: Tokens.fontSans
                        font.pixelSize: Tokens.textData
                        font.weight: Font.DemiBold
                    }
                }
            }
        }

        DownloadMark {
            anchors { top: parent.top; right: parent.right; margins: 8 }
            visible: tile.mark !== undefined
            mark: tile.mark ?? {}
        }

        // How much was watched: the player's timeline in small, white
        // whatever the accent.
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 3
            visible: tile.watched !== undefined
            color: Tokens.watchTrack

            Rectangle {
                width: parent.width * (tile.watched ?? 0)
                height: parent.height
                color: Tokens.text
            }
        }

        // The keyboard's ring, in the accent, findable on any artwork.
        Rectangle {
            anchors.fill: parent
            visible: tile.visualFocus
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
        }
    }
}
