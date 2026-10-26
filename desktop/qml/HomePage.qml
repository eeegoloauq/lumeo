pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
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

    Loading {
        anchors.centerIn: parent
        waiting: home.status === Home.Loading
    }

    Trouble {
        anchors.centerIn: parent
        visible: home.status === Home.Failed || home.status === Home.Empty
        title: home.status === Home.Failed ? qsTrId("homeCatalogueUnavailable") : qsTrId("homeNoCatalogues")
        hint: home.status === Home.Failed ? qsTrId("homeCatalogueUnavailableHint") : qsTrId("homeNoCatalogueHint")
        detail: home.status === Home.Failed ? home.error : ""
        action: home.status === Home.Failed ? qsTrId("commonTryAgain") : ""
        onActed: home.load()
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

            readonly property var item: home.hero
            // What the screen has left above one whole shelf, less the part
            // that lies over the artwork; a floor below which it stops being
            // a picture, and a ceiling past which the page is a screen with
            // nothing to pick (decisions/interface.md).
            readonly property real reveal: page.shelfHeight + page.shelfGap - page.overlap
            readonly property real derived: Theme.whole(Math.max(420, Math.min(720, list.height - reveal)), Screen.devicePixelRatio)

            width: list.width
            height: banner.height + reveal

            Item {
                id: banner
                width: parent.width
                // The least it is; what it holds can make it taller.
                height: Math.max(hero.derived, Theme.whole(words.implicitHeight + page.barClearance + 128, Screen.devicePixelRatio))

                Banner {
                    anchors.fill: parent
                    url: hero.item.background ?? ""
                }

                Column {
                    id: words
                    x: Tokens.gutter
                    width: parent.width - 2 * Tokens.gutter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 128

                    Heading {
                        width: parent.width
                        item: hero.item
                        strongRating: true
                        facts: [Format.years(hero.item), hero.item.runtime,
                                (hero.item.genres ?? []).slice(0, 2).join(" / ")]
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
