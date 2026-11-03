import QtQuick

// A page's wheel, shared with legato. Declare it beside the view it scrolls, after it, so it lies on
// top: `WheelScroll { flickable: view }`.
//
// A step per notch that glides to a stop. The step is GTK 4's: the view's height to the power 2/3
// (gtkscrolledwindow.c, get_wheel_detent_scroll_step), about 90 px in an 860 px view, so a notch
// goes as far as in other GNOME apps. No acceleration: quick notches add up but each goes the
// same distance (an earlier version multiplied them up to four times, and spins flew past).
// Turning back starts from where the page is, not from the unfinished target ahead of it.
//
// Which delta: Qt Wayland sends a mouse wheel with both angleDelta (120 a notch) and the
// compositor's pixelDelta (10-15 px a notch) and no scroll phase; only a touchpad gesture has
// phases (qwaylandinputdevice.cpp). So a phase means fingers, moved 1:1 by pixelDelta, and no
// phase means a wheel, moved by angleDelta. Taking pixelDelta whenever it is set made a notch 10 px.
//
// Where: a handler declared inside a Flickable is moved into its contentItem, whose bounds are not
// the visible view (a header lies above them, content heights are estimates), and wheels outside
// them went to Flickable's own wheel. This layer covers the view itself instead. Shift and
// sideways turns pass through to what is under it, such as a horizontal strip.
Item {
    id: layer

    required property Flickable flickable
    // How long a glide takes; a test sets 0.
    property int duration: 120
    readonly property real step: Math.round(Math.pow(Math.max(flickable.height, 1), 2 / 3))

    property real goal
    property int direction: 0
    readonly property alias glide: animation
    // --wheel-debug logs what each wheel event carries.
    readonly property bool diagnostics: Qt.application.arguments.indexOf("--wheel-debug") >= 0

    // The viewer moved the page.
    signal moved()

    x: flickable.x
    y: flickable.y
    width: flickable.width
    height: flickable.height
    // Over its view only while the view is there to scroll.
    z: flickable.z
    visible: flickable.visible
    enabled: flickable.enabled && flickable.interactive

    // Returns false for a wheel the page leaves to what is under it.
    function scroll(event) {
        const angle = event.angleDelta.y
        const pixels = event.pixelDelta.y
        if (diagnostics)
            console.info("wheel:", JSON.stringify({ phase: event.phase, angleX: event.angleDelta.x, angleY: angle,
                                                   pixelY: pixels, modifiers: event.modifiers, y: flickable.contentY }))
        const sideways = Math.abs(event.angleDelta.x) > Math.abs(angle) || Math.abs(event.pixelDelta.x) > Math.abs(pixels)
        if ((event.modifiers & Qt.ShiftModifier) || sideways || (angle === 0 && pixels === 0))
            return false
        moved()
        const top = flickable.originY - flickable.topMargin
        const bottom = Math.max(top, flickable.originY + flickable.contentHeight + flickable.bottomMargin - flickable.height)
        const clamp = y => Math.max(top, Math.min(y, bottom))
        flickable.cancelFlick()
        if (event.phase !== Qt.NoScrollPhase || angle === 0) {
            // Fingers on a touchpad, or a device with pixels only: the page follows them.
            animation.stop()
            direction = 0
            flickable.contentY = clamp(flickable.contentY - (pixels !== 0 ? pixels : angle / 8))
            return true
        }
        // In proportion to the turn, so a high-resolution wheel's eighths of a notch add up alike.
        const notches = angle / 120
        const turn = notches < 0 ? -1 : 1
        const sameWay = animation.running && turn === direction
        direction = turn
        goal = clamp((sameWay ? goal : flickable.contentY) - notches * step)
        animation.to = goal
        animation.restart()
        return true
    }

    WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        // Shift with the wheel is sideways, for the strip under the page; a handler that saw it
        // could no longer hand it on.
        acceptedModifiers: Qt.NoModifier
        onWheel: event => event.accepted = layer.scroll(event)
    }

    NumberAnimation {
        id: animation

        target: layer.flickable
        property: "contentY"
        duration: layer.duration
        easing.type: Easing.OutCubic
    }

    // A drag takes over from a glide.
    Connections {
        target: layer.flickable
        function onDraggingChanged() {
            if (layer.flickable.dragging)
                animation.stop()
        }
    }
}
