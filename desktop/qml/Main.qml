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
    color: Tokens.page

    // The Basic style's controls read their colours from here.
    palette {
        window: Tokens.page
        windowText: Tokens.text
        base: Tokens.raised
        alternateBase: Tokens.surface
        text: Tokens.text
        button: Tokens.floating
        buttonText: Tokens.text
        highlight: Theme.accent
        highlightedText: Tokens.page
        placeholderText: Tokens.muted
        mid: Tokens.line
        light: Tokens.line
        dark: Tokens.surface
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
        shell.forceActiveFocus()
    }

    Connections {
        target: Prototype
        function onPlayable(url) { window.play(url) }
    }

    Component.onCompleted: {
        if (toOpen === "")
            return
        if (toOpen.indexOf("://") > 0)
            play(toOpen)
        else
            Prototype.openLocal(toOpen)
    }

    Shell {
        id: shell
        // The prototype waits for the file; the player screen takes over in
        // docs/qt-port.md, step 3.
        onWatch: downloadId => Prototype.watch(downloadId)
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
