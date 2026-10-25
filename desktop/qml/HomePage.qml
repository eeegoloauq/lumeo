pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Lumeo
import "format.js" as Format

// The hero, picked from the first shelf, and the shelves under it. The
// first shelf lies over the hero's foot, so the page reads as one surface.
ShellPage {
    id: page

    // A title to open, or to open and start.
    signal open(var item, bool play)

    // A shelf's label and posters, and the space between two shelves.
    readonly property real shelfHeight: Tokens.textShelf * 1.25 + 14 + 246
    readonly property real shelfGap: 28
    // How far the first shelf lies over the hero.
    readonly property real overlap: 84
    // Where the type starts, under the bar that floats over the page.
    readonly property real barClearance: 90

    readonly property bool heroShown: home.status === Home.Ready && home.hero.id !== undefined

    // Where the keyboard is among the stops Up and Down move through: the
    // hero's buttons, the shelf over the hero, then the shelves; -1 before
    // any of them.
    property int stop: -1
    readonly property int firstShelf: heroShown ? 2 : 0

    function focusStop(at) {
        if (at < firstShelf) {
            list.positionViewAtBeginning()
            const top = list.itemAtIndex(0).block
            if (at === 0) {
                top.play.forceActiveFocus(Qt.TabFocusReason)
                return true
            }
            return top.lead.focusCard()
        }
        // The list's first item is the hero, or the margin under the bar.
        const index = at - firstShelf + 1
        if (index >= list.count)
            return false
        list.positionViewAtIndex(index, ListView.Contain)
        return list.itemAtIndex(index)?.block.focusCard() ?? false
    }

    // A shelf with nothing in it yet, or ever, is passed over.
    function move(direction) {
        for (let at = stop + direction; at >= 0 && at < firstShelf + list.count - 1; at += direction)
            if (focusStop(at))
                return
    }

    function chosen(item, progress) {
        // A card of watch progress plays; any other opens its title.
        page.open(item, progress)
    }

    scrolled: list.contentY - list.originY > 12
    Keys.onUpPressed: move(-1)
    Keys.onDownPressed: move(1)

    Home { id: home }

    BusyIndicator {
        anchors.centerIn: parent
        width: 32
        height: 32
        palette.dark: Theme.accent
        // Only past a wait worth showing, or it blinks on every fast answer.
        visible: home.status === Home.Loading && !patience.running
        running: visible

        Timer {
            id: patience
            interval: 300
            running: home.status === Home.Loading
        }
    }

    // An empty screen is an invitation to act: what is missing, and the one
    // thing that can help.
    Column {
        anchors.centerIn: parent
        width: Math.min(460, parent.width - 2 * Tokens.gutter)
        visible: home.status === Home.Failed || home.status === Home.Empty
        spacing: 12

        Text {
            width: parent.width
            text: home.status === Home.Failed ? qsTrId("homeCatalogueUnavailable") : qsTrId("homeNoCatalogues")
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 26
            font.weight: Font.Bold
            wrapMode: Text.Wrap
        }
        Text {
            width: parent.width
            text: home.status === Home.Failed ? qsTrId("homeCatalogueUnavailableHint") : qsTrId("homeNoCatalogueHint")
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: 15
            lineHeightMode: Text.FixedHeight
            lineHeight: 15 * 1.5
            wrapMode: Text.Wrap
        }
        Text {
            width: parent.width
            visible: home.status === Home.Failed
            text: home.error
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            wrapMode: Text.Wrap
        }
        Item { width: 1; height: 10; visible: home.status === Home.Failed }
        QuietButton {
            visible: home.status === Home.Failed
            text: qsTrId("commonTryAgain")
            onClicked: home.load()
        }
    }

    ListView {
        id: list
        objectName: "shelves"
        anchors.fill: parent
        visible: home.status === Home.Ready
        // The hero first, as an item rather than the header: a header that
        // grows as the window does leaves the list where it ended.
        model: home.status === Home.Ready ? [null].concat(home.shelves) : []
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        // No current shelf, which would take the keyboard as the page opens.
        currentIndex: -1
        // Shelves load when built, and a few screens of them stay built, so
        // one scrolled sideways is where it was on the way back up.
        cacheBuffer: 3000
        footer: Item { width: 1; height: 40 }

        delegate: Item {
            id: slot

            required property int index
            required property var modelData
            readonly property Item block: loader.item as Item

            width: list.width
            height: !block || !block.visible ? 0 : block.height + (index > 0 ? page.shelfGap : 0)

            Loader {
                id: loader
                width: parent.width
                sourceComponent: slot.index > 0 ? shelfComponent : page.heroShown ? heroComponent : clearance

                Component {
                    id: shelfComponent

                    ShelfRow {
                        id: row
                        shelf: slot.modelData
                        onChosen: item => page.chosen(item, row.progress)
                        // A card reached by Tab is brought into view with its
                        // shelf.
                        onHoldsKeysChanged: {
                            if (!row.holdsKeys)
                                return
                            page.stop = page.firstShelf + slot.index - 1
                            list.positionViewAtIndex(slot.index, ListView.Contain)
                        }
                    }
                }
            }
        }
    }

    // Without a hero the shelves start under the bar.
    Component {
        id: clearance
        Item { width: list.width; height: page.barClearance }
    }

    Component {
        id: heroComponent

        // The hero and the shelf over its foot in one box, which the hero
        // sizes: a hero grown to fit a short window keeps the shelf under its
        // buttons rather than over them.
        Item {
            id: hero

            readonly property alias lead: foot
            readonly property alias play: play

            // Whole device pixels: a height inside a pixel antialiases that
            // row and the scrim's, and the picture shows through as a line
            // where the banner ends.
            function whole(value) {
                return Math.ceil(value * Screen.devicePixelRatio - 1e-6) / Screen.devicePixelRatio
            }

            readonly property var item: home.hero
            // What the screen has left above one whole shelf, less the part
            // that lies over the artwork; a floor below which it stops being
            // a picture, and a ceiling past which the page is a screen with
            // nothing to pick (decisions/interface.md).
            readonly property real reveal: page.shelfHeight + page.shelfGap - page.overlap
            readonly property real derived: whole(Math.max(420, Math.min(720, list.height - reveal)))

            width: list.width
            height: banner.height + reveal

            Item {
                id: banner
                width: parent.width
                // The least it is; what it holds can make it taller.
                height: Math.max(hero.derived, hero.whole(words.implicitHeight + page.barClearance + 128))

                Rectangle {
                    anchors.fill: parent
                    color: Tokens.surface
                    visible: art.status !== Image.Ready
                }
                Image {
                    id: art
                    anchors.fill: parent
                    source: Format.art(hero.item.background)
                    // The window can grow to the screen; not past it.
                    sourceSize.width: Screen.width
                    fillMode: Image.PreserveAspectCrop
                    verticalAlignment: Image.AlignTop
                }
                ShaderEffect {
                    anchors.fill: parent
                    property color ground: Tokens.page
                    fragmentShader: "qrc:/qt/qml/Lumeo/shaders/scrim.frag.qsb"
                }

                Column {
                    id: words
                    x: Tokens.gutter
                    width: parent.width - 2 * Tokens.gutter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 128

                    // Type over a frame we do not control keeps a shadow.
                    Column {
                        width: parent.width
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            shadowColor: "#cc000000"
                            shadowBlur: 0.55
                            shadowHorizontalOffset: 0
                            shadowVerticalOffset: 2
                        }

                        // The title card the provider drew; set type is the
                        // fallback.
                        Loader {
                            width: Math.min(640, parent.width)
                            sourceComponent: hero.item.logo ? logo : name
                        }
                        Item { width: 1; height: 14 }
                        Row {
                            width: parent.width
                            spacing: 6

                            readonly property string rating: Format.rating(hero.item.imdbRating, Qt.locale())

                            Text {
                                visible: parent.rating !== ""
                                text: parent.rating
                                color: Tokens.text
                                font.family: Tokens.fontSans
                                font.pixelSize: Tokens.textMeta
                                font.weight: Font.Bold
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
                                text: [Format.years(hero.item), hero.item.runtime ?? "",
                                       (hero.item.genres ?? []).slice(0, 2).join(" / ")]
                                      .filter(part => part !== "").join(" · ")
                                color: Tokens.dim
                                font.family: Tokens.fontSans
                                font.pixelSize: Tokens.textMeta
                                font.weight: Font.Medium
                                font.letterSpacing: 0.1
                                elide: Text.ElideRight
                            }
                        }
                        Item { width: 1; height: 12; visible: overview.visible }
                        Text {
                            id: overview
                            width: Math.min(520, parent.width)
                            visible: text !== ""
                            text: hero.item.overview ?? ""
                            color: Tokens.text
                            font.family: Tokens.fontSans
                            font.pixelSize: Tokens.textBody
                            lineHeightMode: Text.FixedHeight
                            lineHeight: Tokens.textBody * 1.45
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }
                    }
                    Item { width: 1; height: 22 }
                    Row {
                        spacing: 10

                        PlayButton {
                            id: play
                            objectName: "play"
                            text: qsTrId("commonPlay")
                            onClicked: page.open(hero.item, true)
                            onActiveFocusChanged: if (activeFocus) page.stop = 0
                        }
                        QuietButton {
                            objectName: "moreInfo"
                            text: qsTrId("homeMoreInfo")
                            onClicked: page.open(hero.item, false)
                            onActiveFocusChanged: if (activeFocus) page.stop = 0
                        }
                    }
                }

                Component {
                    id: logo
                    HeroLogo { url: hero.item.logo; title: hero.item.title }
                }
                Component {
                    id: name
                    Text {
                        text: hero.item.title
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

            ShelfRow {
                id: foot
                y: banner.height - page.overlap
                width: parent.width
                shelf: home.lead
                onChosen: item => page.chosen(item, foot.progress)
                onHoldsKeysChanged: if (holdsKeys) page.stop = 1
            }
        }
    }
}
