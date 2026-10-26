pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Lumeo
import "format.js" as Format

// What a banner says: the title card the provider drew, or the title set in
// type, a line of facts, and the overview. Over a frame we do not control
// the type keeps a shadow.
Column {
    id: heading

    required property var item
    // The facts after the rating, in order; empty ones are left out.
    property var facts: []
    // The rating bold, where it heads the line on its own.
    property bool strongRating
    property real overviewWidth: 520
    property int overviewLines: 3
    property real overviewGap: 12

    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: "#cc000000"
        shadowBlur: 0.55
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

    Loader {
        width: Math.min(640, heading.width)
        sourceComponent: heading.item.logo ? logo : name

        Component {
            id: logo
            HeroLogo { url: heading.item.logo; title: heading.item.title }
        }
        Component {
            id: name
            Text {
                text: heading.item.title ?? ""
                color: "white"
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textHero
                font.weight: Font.Bold
                font.letterSpacing: -1.2
                lineHeightMode: Text.FixedHeight
                lineHeight: Tokens.textHero * 1.05
                wrapMode: Text.Wrap
            }
        }
    }
    Item { width: 1; height: 14 }
    Row {
        width: parent.width
        spacing: 6

        readonly property string rating: Format.rating(heading.item.imdbRating, Qt.locale())

        Text {
            visible: parent.rating !== ""
            text: parent.rating
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textMeta
            font.weight: heading.strongRating ? Font.Bold : Font.Medium
        }
        Text {
            visible: parent.rating !== ""
            text: "·"
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textMeta
        }
        Text {
            width: Math.min(implicitWidth, parent.width - x)
            text: heading.facts.filter(part => !!part).join(" · ")
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textMeta
            font.weight: Font.Medium
            font.letterSpacing: 0.1
            elide: Text.ElideRight
        }
    }
    Item { width: 1; height: heading.overviewGap; visible: overview.visible }
    Text {
        id: overview
        width: Math.min(heading.overviewWidth, parent.width)
        visible: text !== ""
        text: heading.item.overview ?? ""
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textBody
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.textBody * 1.45
        wrapMode: Text.Wrap
        maximumLineCount: heading.overviewLines
        elide: Text.ElideRight
    }
}
