import QtQuick

// A page's wheel: a long step per notch that glides to a stop, notches that
// come quickly adding up. Flickable's own wheel drops what is left of one
// notch when the next arrives, so spinning faster scrolled less; on Wayland
// it also moves by the compositor's 15 px. A touchpad, which says where its
// gesture begins and ends, moves the page under the fingers.
WheelHandler {
    id: wheel

    required property Flickable view
    // How long a glide takes; a test sets 0.
    property int duration: 260

    readonly property real step: 120
    property real goal

    target: null
    orientation: Qt.Vertical

    onWheel: event => {
        const top = view.originY - view.topMargin
        const bottom = Math.max(top, view.originY + view.contentHeight + view.bottomMargin - view.height)
        const clamp = y => Math.max(top, Math.min(y, bottom))
        if (event.phase !== Qt.NoScrollPhase) {
            glide.stop()
            view.contentY = clamp(view.contentY - event.pixelDelta.y)
            return
        }
        goal = clamp((glide.running ? goal : view.contentY) - event.angleDelta.y / 120 * step)
        glide.to = goal
        glide.restart()
    }

    property NumberAnimation glide: NumberAnimation {
        target: wheel.view
        property: "contentY"
        duration: wheel.duration
        easing.type: Easing.OutCubic
    }

    // A drag takes over from a glide.
    property Connections dragging: Connections {
        target: wheel.view
        function onDraggingChanged() { if (wheel.view.dragging) wheel.glide.stop() }
    }
}
