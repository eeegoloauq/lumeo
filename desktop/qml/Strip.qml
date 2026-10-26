pragma ComponentBehavior: Bound

import QtQuick
import Lumeo

// A row that scrolls sideways the way a desktop expects. The wheel stays
// the page's, since a row that took it would stop the page wherever the
// pointer rests; sideways is a trackpad's own gesture, shift with the
// wheel, and an arrow at each end, shown on hover where there is more.
ListView {
    id: strip

    // The index of the card that has the keyboard, or -1.
    property int focused: -1

    orientation: ListView.Horizontal
    spacing: 8
    leftMargin: Tokens.gutter
    rightMargin: Tokens.gutter
    boundsBehavior: Flickable.StopAtBounds
    // The cards pass the keyboard along themselves, so it moves with the
    // focus ring rather than with currentIndex.
    keyNavigationEnabled: false
    currentIndex: -1

    // The first card wholly on screen, for the keyboard arriving from
    // another row.
    function firstShown() {
        const at = indexAt(contentX + leftMargin + 1, height / 2)
        return at < 0 ? 0 : at
    }

    // Card [index] at the start of the row, after the gutter, as far as the
    // row goes.
    function place(index) {
        positionViewAtIndex(index, ListView.Beginning)
        contentX = Math.max(originX - leftMargin,
                            Math.min(contentX - leftMargin,
                                     originX + contentWidth + rightMargin - width))
    }

    function focusCard(index) {
        if (index < 0 || index >= count)
            return false
        positionViewAtIndex(index, ListView.Contain)
        itemAtIndex(index)?.forceActiveFocus(Qt.TabFocusReason)
        return true
    }

    function step(direction) {
        const page = width * 0.8 * direction
        slide.to = Math.max(originX - leftMargin,
                            Math.min(contentX + page, originX + contentWidth + rightMargin - width))
        slide.restart()
    }

    Keys.onLeftPressed: event => event.accepted = focused >= 0 && focusCard(focused - 1)
    Keys.onRightPressed: event => event.accepted = focused >= 0 && focusCard(focused + 1)

    NumberAnimation { id: slide; target: strip; property: "contentX"; duration: 320; easing.type: Easing.OutCubic }

    WheelHandler {
        acceptedModifiers: Qt.ShiftModifier
        orientation: Qt.Vertical
        onWheel: event => {
            const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 72
            strip.contentX = Math.max(strip.originX - strip.leftMargin,
                                      Math.min(strip.contentX - delta,
                                               strip.originX + strip.contentWidth + strip.rightMargin - strip.width))
        }
    }

    HoverHandler { id: hover }

    component Arrow: Rectangle {
        id: arrow
        property bool shown
        property string glyph
        signal pressed()

        width: 44
        height: strip.height
        color: Qt.alpha(Tokens.page, 0.7)
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        Glyph { anchors.centerIn: parent; glyph: arrow.glyph; size: 26 }
        TapHandler { onTapped: arrow.pressed() }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }

    Arrow {
        parent: strip
        anchors.left: parent.left
        glyph: "chevron_left"
        shown: hover.hovered && !strip.atXBeginning
        onPressed: strip.step(-1)
    }
    Arrow {
        parent: strip
        anchors.right: parent.right
        glyph: "chevron_right"
        shown: hover.hovered && !strip.atXEnd
        onPressed: strip.step(1)
    }
}
