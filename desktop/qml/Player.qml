import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// The film and the bar over it. Keys go to mpv as it names them, down and
// up; everything the bar shows is read back from mpv's properties.
FocusScope {
    id: root

    signal back()
    readonly property bool fullscreen: mpv.fullscreen

    function open(url) {
        message.text = ""
        mpv.open(url, Core.headers())
        // A film takes the screen; leaving gives the window back.
        mpv.set("fullscreen", true)
        root.forceActiveFocus()
        chrome.poke()
    }

    function stop() {
        releaseKeys()
        mpv.command(["stop"])
        mpv.set("fullscreen", false)
    }

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = s % 60
        const two = n => (n < 10 ? "0" : "") + n
        return (h > 0 ? h + ":" + two(m) : m) + ":" + two(r)
    }

    MpvItem {
        id: mpv
        anchors.fill: parent
        onEndOfFile: reason => message.text = "mpv: " + reason
        // Esc undoes one thing at a time: fullscreen, then the film.
        onAction: name => {
            if (name === "back" || (name === "escape" && !mpv.fullscreen))
                root.back()
            else if (name === "escape")
                mpv.set("fullscreen", false)
        }
    }

    // mpv's names for the keys that are not characters.
    readonly property var named: ({
        [Qt.Key_Left]: "LEFT", [Qt.Key_Right]: "RIGHT", [Qt.Key_Up]: "UP", [Qt.Key_Down]: "DOWN",
        [Qt.Key_PageUp]: "PGUP", [Qt.Key_PageDown]: "PGDWN", [Qt.Key_Home]: "HOME",
        [Qt.Key_End]: "END", [Qt.Key_Backspace]: "BS", [Qt.Key_Delete]: "DEL",
        [Qt.Key_Return]: "ENTER", [Qt.Key_Enter]: "KP_ENTER", [Qt.Key_Tab]: "TAB",
        [Qt.Key_Insert]: "INS", [Qt.Key_Space]: "SPACE", [Qt.Key_Escape]: "ESC",
        [Qt.Key_F1]: "F1", [Qt.Key_F2]: "F2", [Qt.Key_F3]: "F3", [Qt.Key_F4]: "F4",
        [Qt.Key_F5]: "F5", [Qt.Key_F6]: "F6", [Qt.Key_F7]: "F7", [Qt.Key_F8]: "F8",
        [Qt.Key_F9]: "F9", [Qt.Key_F10]: "F10", [Qt.Key_F11]: "F11", [Qt.Key_F12]: "F12",
    })

    function mpvName(event) {
        let prefix = ""
        if (event.modifiers & Qt.ControlModifier) prefix += "Ctrl+"
        if (event.modifiers & Qt.AltModifier) prefix += "Alt+"
        const name = named[event.key]
        if (name !== undefined)
            return prefix + (event.modifiers & Qt.ShiftModifier ? "Shift+" : "") + name
        // With Ctrl the text is a control character; the key code is the letter.
        if (prefix !== "" && event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
            return prefix + String.fromCharCode(event.key).toLowerCase()
        const text = event.text
        if (text.length === 1 && text.charCodeAt(0) > 0x20 && text.charCodeAt(0) < 0x7f)
            return prefix + text
        return ""
    }

    // Keys mpv still holds, by Qt's key code: a key released after focus
    // left would otherwise repeat in mpv for ever.
    property var held: ({})

    function releaseKeys() {
        for (const key in held)
            mpv.key(held[key], false)
        held = {}
    }

    onActiveFocusChanged: if (!activeFocus) releaseKeys()

    Keys.onPressed: event => {
        event.accepted = true
        if (event.isAutoRepeat)
            return
        const name = mpvName(event)
        if (name === "")
            return
        held[event.key] = name
        mpv.key(name, true)
    }

    Keys.onReleased: event => {
        event.accepted = true
        if (event.isAutoRepeat || held[event.key] === undefined)
            return
        mpv.key(held[event.key], false)
        delete held[event.key]
    }

    // The picture: a click pauses as it lands, a second one within the
    // interval takes the pause back and goes fullscreen.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: chrome.shown ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: chrome.poke()
    }

    TapHandler {
        onTapped: (point, button) => {
            mpv.command(["cycle", "pause"])
            if (tapCount === 2)
                mpv.command(["cycle", "fullscreen"])
        }
    }

    WheelHandler {
        onWheel: event => mpv.command(["keypress", event.angleDelta.y > 0 ? "WHEEL_UP" : "WHEEL_DOWN"])
    }

    Label {
        id: message
        anchors.centerIn: parent
        color: "#f3f5f9"
        font.pixelSize: 18
    }

    Label {
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 24 }
        text: Prototype.status
        color: "#c3cad8"
    }

    // The bar: up when the pointer moves, gone half a second after it
    // stops, held while the pointer rests on it or a button is down.
    Item {
        id: chrome

        property bool shown: true

        function poke() {
            shown = true
            idle.restart()
        }

        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 120
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Timer {
            id: idle
            interval: 500
            onTriggered: chrome.shown = bar.hovered || seek.pressed || volume.pressed
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: "#cc000000" }
            }
        }

        HoverHandler { id: bar }

        ColumnLayout {
            anchors { fill: parent; leftMargin: 24; rightMargin: 24; bottomMargin: 16 }
            spacing: 4

            Item { Layout.fillHeight: true }

            // Dragged, it seeks by keyframes so the picture follows the
            // thumb; released, it seeks exactly.
            Slider {
                id: seek
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                from: 0
                to: Math.max(mpv.duration, 1)
                value: pressed ? value : mpv.position
                onMoved: mpv.command(["seek", String(value), "absolute+keyframes"])
                onPressedChanged: if (!pressed) mpv.command(["seek", String(value), "absolute+exact"])
            }

            RowLayout {
                spacing: 16

                Button {
                    focusPolicy: Qt.NoFocus
                    flat: true
                    text: mpv.paused ? "▶" : "❚❚"
                    onClicked: mpv.command(["cycle", "pause"])
                }

                Label {
                    color: "#f3f5f9"
                    text: root.clock(mpv.position) + " / " + root.clock(mpv.duration)
                }

                Item { Layout.fillWidth: true }

                Label {
                    color: "#8b8f9c"
                    text: mpv.hwdec === "" ? "software" : mpv.hwdec
                }

                Button {
                    focusPolicy: Qt.NoFocus
                    flat: true
                    checkable: true
                    checked: mpv.anime4k
                    text: "Anime4K"
                    onClicked: mpv.toggleAnime4k()
                }

                Slider {
                    id: volume
                    focusPolicy: Qt.NoFocus
                    from: 0
                    to: 150
                    value: pressed ? value : mpv.volume
                    onMoved: mpv.set("volume", value)
                }

                Button {
                    focusPolicy: Qt.NoFocus
                    flat: true
                    text: mpv.fullscreen ? "Window" : "Full"
                    onClicked: mpv.command(["cycle", "fullscreen"])
                }
            }
        }
    }
}
