pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

ApplicationWindow {
    id: window

    // A file to play at once, from the command line.
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
    property Player player: null
    // The window was asked to close while a film played: it closes once the
    // film's position is saved.
    property bool quitting: false

    // A film takes the screen when it starts; leaving it gives the window
    // back as it was (decisions/player.md).
    function play(downloadId, name) {
        if (player)
            return
        before = visibility === Window.FullScreen ? Window.Windowed : visibility
        player = playerComponent.createObject(window.contentItem, {downloadId: downloadId, name: name})
        player.forceActiveFocus()
        player.mpv.set("fullscreen", true)
    }

    // A window that leaves fullscreen by other means takes mpv along, so
    // that its `f` goes the right way.
    onVisibilityChanged: {
        const full = window.visibility === Window.FullScreen
        if (player && !player.playback.closing && player.mpv.fullscreen !== full)
            player.mpv.set("fullscreen", full)
    }

    onClosing: close => {
        if (!player)
            return
        close.accepted = false
        quitting = true
        player.close()
    }

    Connections {
        target: Prototype
        function onStarted(downloadId, name) { window.play(downloadId, name) }
    }

    Component.onCompleted: if (toOpen !== "") Prototype.openLocal(toOpen)

    Shell {
        id: shell
        anchors.fill: parent
        visible: !window.player?.visible
        focus: true
        onWatch: (downloadId, name) => window.play(downloadId, name)
    }

    Component {
        id: playerComponent

        Player {
            id: film
            anchors.fill: parent
            onFullscreenChanged: if (!film.playback.closing) window.visibility = film.fullscreen ? Window.FullScreen : window.before
            onClosed: {
                film.visible = false
                window.visibility = window.before
                shell.forceActiveFocus()
            }
            // mpv goes with the item, before the process ends: the GPU
            // driver's exit handlers would tear down what it still uses.
            onFinished: {
                window.player = null
                film.destroy()
                if (window.quitting)
                    window.close()
            }
        }
    }
}
