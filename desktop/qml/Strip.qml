pragma ComponentBehavior: Bound

import QtQuick
import Lumeo

// A row that scrolls sideways the way a desktop expects. The wheel stays
// the page's, since a row that took it would stop the page wherever the
// pointer rests; sideways is a trackpad's own gesture, shift with the
// wheel, and an arrow at each end, shown on hover where there is more.
// The arrows and the hover sit beside the list, not in it: a Flickable
// loses its own hover to a child that takes hover, so an arrow inside
// hid itself as soon as it was pointed at, and came back, over and over.
FocusScope {
    id: strip

    // The index of the card that has the keyboard, or -1.
    property int focused: -1
    property alias model: list.model
    property alias delegate: list.delegate
    property alias spacing: list.spacing
    property alias topMargin: list.topMargin
    readonly property alias count: list.count
    readonly property alias contentX: list.contentX
    readonly property alias originX: list.originX
    readonly property alias contentWidth: list.contentWidth

    function itemAtIndex(index) {
        return list.itemAtIndex(index)
    }

    function positionViewAtIndex(index, mode) {
        list.positionViewAtIndex(index, mode)
    }

    // The first card wholly on screen, for the keyboard arriving from
    // another row.
    function firstShown() {
        const at = list.indexAt(list.contentX + list.leftMargin + 1, list.height / 2)
        return at < 0 ? 0 : at
    }

    // Card [index] at the start of the row, after the gutter, as far as the
    // row goes.
    function place(index) {
        list.positionViewAtIndex(index, ListView.Beginning)
        list.contentX = list.clamp(list.contentX - list.leftMargin)
    }

    function focusCard(index) {
        if (index < 0 || index >= count)
            return false
        list.positionViewAtIndex(index, ListView.Contain)
        list.itemAtIndex(index)?.forceActiveFocus(Qt.TabFocusReason)
        return true
    }

    function step(direction) {
        const page = width * 0.8 * direction
        slide.to = list.clamp(list.contentX + page)
        slide.restart()
    }

    Keys.onLeftPressed: event => event.accepted = focused >= 0 && focusCard(focused - 1)
    Keys.onRightPressed: event => event.accepted = focused >= 0 && focusCard(focused + 1)

    ListView {
        id: list

        // contentX held to the row's two ends.
        function clamp(x) {
            return Math.max(originX - leftMargin, Math.min(x, originX + contentWidth + rightMargin - width))
        }

        anchors.fill: parent
        focus: true
        orientation: ListView.Horizontal
        spacing: 8
        leftMargin: Tokens.gutter
        rightMargin: Tokens.gutter
        boundsBehavior: Flickable.StopAtBounds
        // The cards pass the keyboard along themselves, so it moves with the
        // focus ring rather than with currentIndex.
        keyNavigationEnabled: false
        currentIndex: -1
    }

    NumberAnimation { id: slide; target: list; property: "contentX"; duration: 320; easing.type: Easing.OutCubic }

    WheelHandler {
        acceptedModifiers: Qt.ShiftModifier
        orientation: Qt.Vertical
        onWheel: event => {
            const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 72
            list.contentX = list.clamp(list.contentX - delta)
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
        objectName: "back"
        anchors.left: parent.left
        glyph: "chevron_left"
        shown: hover.hovered && !list.atXBeginning
        onPressed: strip.step(-1)
    }
    Arrow {
        objectName: "on"
        anchors.right: parent.right
        glyph: "chevron_right"
        shown: hover.hovered && !list.atXEnd
        onPressed: strip.step(1)
    }
}
