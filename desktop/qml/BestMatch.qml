import QtQuick
import QtQuick.Controls.Basic
import Lumeo
import "format.js" as Format

// The title the word most likely means, over its backdrop: the usual case
// is one Enter or one click, and the grid beside it is for the rest.
AbstractButton {
    id: card

    required property var item

    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    Accessible.name: item.title

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    // Square like the posters beside it: it is artwork too.
    background: Rectangle {
        color: Tokens.raised

        Image {
            id: backdrop
            anchors.fill: parent
            source: Format.art(card.item.background)
            sourceSize.width: 720
            fillMode: Image.PreserveAspectCrop
            opacity: card.hovered || card.visualFocus ? 1 : 0.85
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        // Type on the left needs a ground; the picture keeps the right.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.alpha(Tokens.page, 0.92) }
                GradientStop { position: 0.55; color: Qt.alpha(Tokens.page, 0.6) }
                GradientStop { position: 1; color: Qt.alpha(Tokens.page, 0) }
            }
        }
        // The keyboard's ring, in the accent, as on a poster.
        Rectangle {
            anchors.fill: parent
            visible: card.visualFocus
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
        }
    }

    contentItem: Item {
        Column {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                      leftMargin: 28; rightMargin: 28; bottomMargin: 26 }
            spacing: 8

            Text {
                text: qsTrId("searchBestMatch")
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
                font.capitalization: Font.AllUppercase
            }
            Text {
                width: parent.width
                text: card.item.title
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 30
                font.weight: Font.Bold
                font.letterSpacing: -0.5
                lineHeightMode: Text.FixedHeight
                lineHeight: 34
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: [Format.rating(card.item.imdbRating, Qt.locale()), Format.years(card.item),
                       card.item.kind === "series" ? qsTrId("commonSeries") : qsTrId("commonFilm"),
                       (card.item.genres ?? []).slice(0, 2).join(" / ")].filter(part => !!part).join(" · ")
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textMeta
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Text {
                width: Math.min(parent.width, 460)
                visible: text !== ""
                text: card.item.overview ?? ""
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                lineHeightMode: Text.FixedHeight
                lineHeight: Tokens.textCard * 1.5
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }
    }
}
