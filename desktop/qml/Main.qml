import QtQuick
import QtQuick.Controls
import Lumeo

ApplicationWindow {
    id: window

    // A file or address to play at once, from the command line.
    required property string toOpen

    width: 1280
    height: 800
    visible: true
    title: "Lumeo"
    color: "black"

    palette {
        window: "#000000"
        windowText: "#f3f5f9"
        base: "#17181c"
        alternateBase: "#0e0f12"
        text: "#f3f5f9"
        button: "#1e1f24"
        buttonText: "#f3f5f9"
        highlight: "#f3f5f9"
        highlightedText: "#000000"
        placeholderText: "#8b8f9c"
        mid: "#26272e"
        light: "#26272e"
        dark: "#0e0f12"
    }

    // How the window stood before a film took the screen, to give it back.
    property int before: Window.Windowed

    function play(url) {
        before = window.visibility === Window.FullScreen ? Window.Windowed : window.visibility
        player.visible = true
        player.open(url)
    }

    function leave() {
        player.stop()
        player.visible = false
        window.visibility = before
        browse.forceActiveFocus()
    }

    Connections {
        target: Core
        function onPlayable(url) { window.play(url) }
    }

    Component.onCompleted: {
        if (toOpen === "")
            return
        if (toOpen.indexOf("://") > 0)
            play(toOpen)
        else
            Core.openLocal(toOpen)
    }

    Browse {
        id: browse
        anchors.fill: parent
        visible: !player.visible
        focus: true
    }

    Player {
        id: player
        anchors.fill: parent
        visible: false
        onFullscreenChanged: window.visibility = fullscreen ? Window.FullScreen : window.before
        onBack: window.leave()
    }
}
