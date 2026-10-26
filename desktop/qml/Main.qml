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

    // How the window stands out of fullscreen, to go back to.
    property int windowed: Window.Windowed
    // How a film found the window, to give it back that way.
    property bool wasFullscreen: false
    property Player player: null
    // The window was asked to close while a film played: it closes once the
    // film's position is saved.
    property bool quitting: false

    // A film takes the screen when it starts; leaving it gives the window
    // back as it was (decisions/player.md).
    function play(downloadId, name) {
        const sitting = player
        if (!sitting)
            wasFullscreen = visibility === Window.FullScreen
        player = playerComponent.createObject(window.contentItem, {downloadId: downloadId, name: name})
        player.forceActiveFocus()
        // Another copy or episode in the same sitting keeps the window as it
        // is, and mpv is told so that its `f` goes the right way.
        player.mpv.set("fullscreen", sitting ? visibility === Window.FullScreen : true)
        if (sitting) {
            sitting.handedOver = true
            sitting.close()
        }
    }

    // A window that leaves fullscreen by other means takes mpv along, so
    // that its `f` goes the right way.
    onVisibilityChanged: {
        if (window.visibility === Window.Windowed || window.visibility === Window.Maximized)
            window.windowed = window.visibility
        const full = window.visibility === Window.FullScreen
        if (player && !player.playback.closing && player.mpv.fullscreen !== full)
            player.mpv.set("fullscreen", full)
    }

    onClosing: close => {
        if (!player)
            return
        close.accepted = false
        quitting = true
        const leaving = player
        player = null
        leaving.close()
    }

    Connections {
        target: Prototype
        function onStarted(downloadId, name) { window.play(downloadId, name) }
    }

    Component.onCompleted: if (toOpen !== "") Prototype.openLocal(toOpen)

    // The film has mpv's `f`; the rest of the app has F11, Esc being Back.
    Shortcut {
        sequence: "F11"
        enabled: !window.player
        onActivated: window.visibility = window.visibility === Window.FullScreen ? window.windowed : Window.FullScreen
    }

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
            onFullscreenChanged: if (!film.playback.closing) window.visibility = film.fullscreen ? Window.FullScreen : window.windowed
            onNext: (downloadId, name) => window.play(downloadId, name)
            onStorage: {
                film.close()
                shell.storage()
            }
            onClosed: {
                film.visible = false
                if (film.handedOver)
                    return
                window.visibility = window.wasFullscreen ? Window.FullScreen : window.windowed
                shell.forceActiveFocus()
            }
            // mpv goes with the item, before the process ends: the GPU
            // driver's exit handlers would tear down what it still uses.
            onFinished: {
                if (window.player === film)
                    window.player = null
                film.destroy()
                if (window.quitting && !window.player)
                    window.close()
            }
        }
    }
}
