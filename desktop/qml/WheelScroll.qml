import QtQuick

// A page's wheel: a long step per notch that glides to a stop, notches that
// come quickly adding up and each going farther, so a spin crosses a long
// page while a single notch stays one step. Neither Windows nor libinput
// speeds a wheel up. Flickable's own wheel drops what is left of one
// notch when the next arrives, so spinning faster scrolled less; on Wayland
// it also moves by the compositor's 15 px. A touchpad, which says where its
// gesture begins and ends, moves the page under the fingers.
WheelHandler {
    id: wheel

    required property Flickable flickable
    // How long a glide takes; a test sets 0.
    property int duration: 260

    readonly property real step: 120
    property real goal
    // Notches closer than this many ms in a row add half a step each to the
    // next, up to four steps; a test lengthens it.
    property int burst: 100
    property real gain: 1
    property double last: 0

    // The viewer moved the page.
    signal moved()

    target: null
    orientation: Qt.Vertical

    onWheel: event => {
        moved()
        const top = flickable.originY - flickable.topMargin
        const bottom = Math.max(top, flickable.originY + flickable.contentHeight + flickable.bottomMargin - flickable.height)
        const clamp = y => Math.max(top, Math.min(y, bottom))
        if (event.phase !== Qt.NoScrollPhase) {
            glide.stop()
            flickable.contentY = clamp(flickable.contentY - event.pixelDelta.y)
            return
        }
        // In proportion to the turn, so a high-resolution wheel's eighths of
        // a notch speed it up as much as the notch would.
        const notches = event.angleDelta.y / 120
        const now = Date.now()
        gain = now - last < burst ? Math.min(gain + Math.abs(notches) / 2, 4) : 1
        last = now
        goal = clamp((glide.running ? goal : flickable.contentY) - notches * step * gain)
        glide.to = goal
        glide.restart()
    }

    property NumberAnimation glide: NumberAnimation {
        target: wheel.flickable
        property: "contentY"
        duration: wheel.duration
        easing.type: Easing.OutCubic
    }

    // A drag takes over from a glide.
    property Connections dragging: Connections {
        target: wheel.flickable
        function onDraggingChanged() { if (wheel.flickable.dragging) wheel.glide.stop() }
    }
}
