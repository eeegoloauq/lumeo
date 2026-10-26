pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Lumeo

ApplicationWindow {
    id: window

    width: 1280
    height: 800
    // The smallest the pages were checked at; half of a 1366-wide screen.
    minimumWidth: 640
    minimumHeight: 440
    // A login launch starts hidden, unless the setting has since been
    // turned off.
    visible: !(Instance.background && Background.enabled)
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
    // The app is ending, not going to the background; with a film up, the
    // window closes once the film's position is saved.
    property bool quitting: false

    // The window back from the background, or brought forward by a launch.
    function present() {
        show()
        raise()
        requestActivate()
        Background.shown()
    }

    // Ends the app even where closing would only hide the window, the
    // film's position saved first.
    function quit() {
        quitting = true
        close()
    }

    // The title the "Lumeo keeps what you watch" card names, shown once per
    // machine on leaving the player the first time.
    property string keptTitle: ""

    // A film takes the screen when it starts; leaving it gives the window
    // back as it was (decisions/player.md). [kept]: Lumeo keeps the file,
    // which it never does for one opened from this computer.
    function play(downloadId, name, kept) {
        const sitting = player
        if (!sitting)
            wasFullscreen = visibility === Window.FullScreen
        player = playerComponent.createObject(window.contentItem, {downloadId: downloadId, name: name, kept: kept})
        player.forceActiveFocus()
        // Another copy or episode in the same sitting keeps the window as it
        // is.
        if (!sitting)
            visibility = Window.FullScreen
        if (sitting) {
            sitting.handedOver = true
            sitting.close()
        }
    }

    onVisibilityChanged: {
        if (window.visibility === Window.Windowed || window.visibility === Window.Maximized)
            window.windowed = window.visibility
    }

    // Into the background the film goes with the window: playing on behind
    // none is nobody's wish (decisions/interface.md).
    onClosing: close => {
        if (Background.enabled && !quitting) {
            close.accepted = false
            if (player) {
                const leaving = player
                player = null
                leaving.close()
            }
            visibility = windowed
            hide()
            Background.hidden()
            return
        }
        if (player) {
            close.accepted = false
            quitting = true
            const leaving = player
            player = null
            leaving.close()
            return
        }
        Instance.release()
        Qt.quit()
    }

    // A file or link from the launch that started the app, or from a later
    // one, which brings the window forward.
    Connections {
        target: Instance
        function onOpened(target) {
            window.present()
            if (target !== "")
                Opening.open(target)
        }
        function onReplaced() { window.quit() }
    }

    Connections {
        target: Background
        function onShow() { window.present() }
        function onQuit() { window.quit() }
    }

    Connections {
        target: Opening
        function onPlay(downloadId, name) { window.play(downloadId, name, false) }
        function onTitle(item) { shell.open(item, false) }
        function onFailed(what, reason) {
            shell.say(reason === "" ? qsTrId("commonUnknownLink") : qsTrId("commonCouldNotOpen").arg(what).arg(reason))
        }
    }

    Component.onCompleted: {
        Releases.check()
        if (!visible)
            Background.hidden()
        if (Instance.target() !== "")
            Opening.open(Instance.target())
    }

    Shortcut {
        sequence: "Ctrl+Q"
        context: Qt.ApplicationShortcut
        onActivated: window.quit()
    }

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
        onWatch: (downloadId, name) => window.play(downloadId, name, true)
    }

    // The corner's notice, one at a time: what just happened to the film
    // comes before what is new in Lumeo, and a newer release before the
    // notes of this one, since it covers the update the viewer is on. The
    // column spans the height, so a long card is held to the window.
    Item {
        visible: shell.visible
        anchors { top: parent.top; right: parent.right; bottom: parent.bottom; margins: Theme.edge }
        width: 360

        Loader {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.min(item?.implicitHeight ?? 0, parent.height)
            sourceComponent: window.keptTitle !== "" ? keepsCard
                : Releases.update !== "" ? updateCard
                : Releases.news.length > 0 ? newsCard : null
        }
    }

    Component {
        id: keepsCard
        CornerCard {
            objectName: "keepsCard"
            title: qsTrId("keepsTitle")
            onClosed: window.keptTitle = ""
            Text {
                Layout.fillWidth: true
                text: {
                    const keep = Preferences.current.keep
                    return [qsTrId("keepsHere").arg(window.keptTitle),
                            keep === "watched" ? qsTrId("keepsDeletedWatched")
                            : keep === "days" ? qsTrId("keepsDeletedAfterDays", Preferences.current.keepDays)
                            : keep === "forever" ? qsTrId("keepsStays") : ""].filter(s => s !== "").join(" ")
                }
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                wrapMode: Text.Wrap
            }
            buttons: RowButton {
                text: qsTrId("keepsStorage")
                onClicked: {
                    window.keptTitle = ""
                    shell.storage()
                }
            }
        }
    }
    Component {
        id: updateCard
        ReleaseCard {
            objectName: "updateCard"
            title: qsTrId("releaseAvailable").arg(Releases.update)
            items: Releases.updateNotes
            action: qsTrId("releaseDownload")
            onActed: {
                Qt.openUrlExternally(Releases.updateUrl)
                Releases.dismissUpdate()
            }
            onClosed: Releases.dismissUpdate()
        }
    }
    Component {
        id: newsCard
        ReleaseCard {
            objectName: "newsCard"
            title: qsTrId("releaseUpdatedTo").arg(Qt.application.version)
            items: Releases.news
            // Offered before it was installed, or told beta by beta: the
            // list was read then.
            collapsed: Releases.newsTold
            action: qsTrId("releaseGotIt")
            onActed: Releases.seen()
            onClosed: Releases.seen()
        }
    }

    Component {
        id: playerComponent

        Player {
            id: film
            property bool kept: true
            anchors.fill: parent
            // The window is the one owner of fullscreen: a film asks, and
            // reads it back. mpv's own flag, mirrored both ways, took a stale
            // state the compositor reported for the viewer leaving
            // fullscreen.
            fullscreen: window.visibility === Window.FullScreen
            onFullscreenAsked: on => window.visibility = on ? Window.FullScreen : window.windowed
            onNext: (downloadId, name) => window.play(downloadId, name, film.kept)
            onStorage: {
                film.close()
                shell.storage()
            }
            onClosed: {
                film.visible = false
                if (film.handedOver)
                    return
                if (film.kept && !LocalSettings.keepsTold) {
                    LocalSettings.keepsTold = true
                    window.keptTitle = film.name
                }
                // Closed with the window into the background, which keeps
                // it hidden.
                if (window.visible)
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
