pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// A download playing, with the bar over it. Keys and mouse buttons go to mpv
// as its own keys, down and up; everything the bar shows is read back from
// mpv's properties (decisions/player.md).
FocusScope {
    id: player

    required property string downloadId
    // What the page that started it called it.
    required property string name

    readonly property alias mpv: mpv
    readonly property bool fullscreen: mpv.fullscreen
    readonly property alias playback: session

    // The film is left: the window goes back to the pages.
    signal closed()
    // Its position has reached the core, or three seconds went by: it may go.
    signal finished()

    function close() {
        session.close()
    }

    // The menu open over the bar, "" for none. Which one is the screen's,
    // since mpv's `c` opens one too.
    property string menu: ""

    function toggleMenu(name) {
        menu = menu === name ? "" : name
        if (menu === "tracks")
            session.tracks.show()
        chrome.poke()
    }

    MpvItem {
        id: mpv
        anchors.fill: parent

        // Esc undoes one thing at a time: an open menu, then fullscreen, then
        // the film, so that one stray press does not end it; q leaves at once.
        onAction: name => {
            if (name === "tracks")
                player.toggleMenu("tracks")
            else if (name === "escape" && player.menu !== "")
                player.menu = ""
            else if (name === "back" || (name === "escape" && !mpv.fullscreen))
                player.close()
            else if (name === "escape")
                mpv.set("fullscreen", false)
        }
    }

    Playback {
        id: session
        mpv: mpv
        downloadId: player.downloadId
        name: player.name
        onClosed: player.closed()
        onFinished: player.finished()
        onNotice: (kind, codec) => notice.say(kind === "sound" ? qsTrId("playerNoSoundDecodeFailed").arg(codec)
                                              : kind === "picture" ? qsTrId("playerPictureDecodeFailed").arg(codec)
                                              : qsTrId("playerCouldNotStartFile"))
    }

    // Keys mpv has no name for, such as a modifier alone, go on to the window.
    Keys.onPressed: event => event.accepted = mpv.press(event.key, event.text, event.modifiers,
                                                        event.nativeScanCode, event.isAutoRepeat)
    Keys.onReleased: event => event.accepted = mpv.release(event.key, event.nativeScanCode,
                                                           event.isAutoRepeat)
    onActiveFocusChanged: if (!activeFocus) mpv.releaseKeys()

    // The picture: buttons go to mpv as they change, so its bindings decide,
    // its double click included. Not before there is a picture, or a click
    // would pause a film nobody has seen.
    MouseArea {
        id: picture

        property int sent: Qt.NoButton

        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        cursorShape: chrome.shown ? Qt.ArrowCursor : Qt.BlankCursor

        onPressedButtonsChanged: {
            const now = pressedButtons
            // A click that closes a menu is only that, not a pause.
            if (now !== Qt.NoButton && player.menu !== "") {
                player.menu = ""
                return
            }
            for (const button of [Qt.LeftButton, Qt.RightButton, Qt.MiddleButton, Qt.BackButton, Qt.ForwardButton]) {
                const down = (now & button) !== 0
                if (down === ((sent & button) !== 0) || (down && !mpv.hasPicture))
                    continue
                mpv.button(button, down)
                sent = down ? sent | button : sent & ~button
            }
            chrome.held = now !== Qt.NoButton
            chrome.poke()
        }
        onPositionChanged: mouse => {
            if (mpv.hasPicture)
                mpv.pointer(mouse.x, mouse.y)
            chrome.poke()
        }
        onWheel: wheel => {
            if (mpv.hasPicture)
                mpv.wheel(wheel.angleDelta, wheel.modifiers)
        }
    }

    PlayerWaiting {
        anchors.fill: parent
        visible: !mpv.hasPicture
        playback: session
    }

    BusyIndicator {
        anchors.centerIn: parent
        width: 56
        height: 56
        visible: mpv.buffering && mpv.hasPicture
        running: visible
        palette.dark: "white"
    }

    // A short line over the picture, gone after eight seconds.
    Rectangle {
        id: notice

        function say(text) {
            line.text = text
            visible = true
            forget.restart()
        }

        anchors { top: parent.top; topMargin: 84; horizontalCenter: parent.horizontalCenter }
        visible: false
        width: Math.min(line.implicitWidth, player.width - 48) + 28
        height: line.implicitHeight + 18
        radius: Tokens.radiusControl
        color: Qt.alpha(Tokens.floating, 0.92)
        border.color: Tokens.rim

        Text {
            id: line
            objectName: "notice"
            anchors.centerIn: parent
            width: parent.width - 28
            wrapMode: Text.Wrap
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textCard
        }

        Timer { id: forget; interval: 8000; onTriggered: notice.visible = false }
    }

    // The bar follows the mouse and nothing else: up when the pointer moves,
    // gone half a second after it stops. A pointer on a band or a button held
    // keeps it; a key, a pause or a seek does not bring it up.
    Item {
        id: chrome

        property bool shown: true
        property bool held: false
        readonly property bool overBand: topHover.hovered || bottomHover.hovered

        function poke() {
            shown = true
            idle.restart()
        }

        anchors.fill: parent
        opacity: shown ? 1 : 0
        enabled: shown
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        onOverBandChanged: poke()
        onHeldChanged: if (!held) poke()

        Timer {
            id: idle
            interval: 500
            running: true
            onTriggered: chrome.shown = !mpv.hasPicture || chrome.overBand || chrome.held
                                        || seek.pressed || volume.pressed || player.menu !== ""
        }
        Connections {
            target: mpv
            function onHasPictureChanged() { if (mpv.hasPicture) chrome.poke() }
        }

        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 72
            gradient: Gradient {
                GradientStop { position: 0; color: "#8c000000" }
                GradientStop { position: 1; color: "transparent" }
            }
        }

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 120
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: "#b3000000" }
            }
        }

        // A band takes every click and wheel that misses its controls, so
        // none of them reaches the picture.
        MouseArea {
            anchors.fill: topBand
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        RowLayout {
            id: topBand
            anchors { left: parent.left; right: parent.right; top: parent.top }
            anchors { leftMargin: 24; rightMargin: 14; topMargin: 16 }
            height: 40
            spacing: 16

            HoverHandler { id: topHover }

            PlayerButton {
                objectName: "playerBack"
                glyph: "arrow_back"
                tip: qsTrId("playerBackEsc")
                onClicked: player.close()
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: session.title
                    elide: Text.ElideRight
                    color: "white"
                    font.family: Tokens.fontSans
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }

                Text {
                    readonly property int season: session.download.season ?? 0
                    readonly property int episode: session.download.episode ?? 0

                    Layout.fillWidth: true
                    visible: episode > 0
                    text: !visible ? "" : session.episodeTitle === ""
                        ? qsTrId("playerEpisodeId").arg(season).arg(episode)
                        : qsTrId("playerEpisodeTitle").arg(season).arg(episode).arg(session.episodeTitle)
                    elide: Text.ElideRight
                    color: "#b3ffffff"
                    font.family: Tokens.fontSans
                    font.pixelSize: 13
                }
            }
        }

        MouseArea {
            anchors.fill: bottomBand
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            id: bottomBand
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            anchors { leftMargin: 16; rightMargin: 16; bottomMargin: 8 }
            spacing: 4

            HoverHandler { id: bottomHover }

            // Dragged, it pauses and seeks by keyframes so the picture
            // follows the thumb; released, it seeks exactly and plays on.
            Scrubber {
                id: seek

                property bool wasPlaying: false

                objectName: "seekBar"
                Layout.fillWidth: true
                duration: mpv.duration
                time: mpv.position
                chapters: mpv.chapters
                acquired: {
                    const progress = session.download.progress ?? {}
                    return progress.total > 0 ? progress.completed / progress.total : 0
                }
                onMoved: mpv.command(["seek", String(value * duration), "absolute+keyframes"])
                onPressedChanged: {
                    if (pressed) {
                        wasPlaying = !mpv.paused
                        if (wasPlaying)
                            mpv.set("pause", true)
                        return
                    }
                    mpv.command(["seek", (value * duration).toFixed(3), "absolute+exact"])
                    if (wasPlaying)
                        mpv.set("pause", false)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                spacing: 0

                PlayerButton {
                    objectName: "playPause"
                    glyph: mpv.paused ? "play_arrow" : "pause"
                    tip: mpv.paused ? qsTrId("playerPlaySpace") : qsTrId("playerPauseSpace")
                    onClicked: if (mpv.hasPicture) mpv.command(["cycle", "pause"])
                }

                // The slider shows under the pointer; the mark on it is 100%,
                // past which mpv amplifies.
                Row {
                    id: volumeControl

                    readonly property real shown: mpv.muted ? 0 : mpv.volume
                    // What the button gives back after the slider went to zero.
                    property real audible: 100

                    HoverHandler { id: volumeHover }

                    Connections {
                        target: mpv
                        function onVolumeChanged() { if (mpv.volume > 0) volumeControl.audible = mpv.volume }
                    }

                    PlayerButton {
                        objectName: "mute"
                        glyph: volumeControl.shown === 0 ? "volume_off"
                            : volumeControl.shown < 60 ? "volume_down" : "volume_up"
                        tip: mpv.muted ? qsTrId("playerUnmute") : qsTrId("playerMute")
                        onClicked: {
                            if (mpv.volume === 0) {
                                mpv.set("volume", volumeControl.audible)
                                mpv.set("mute", false)
                            } else {
                                mpv.command(["cycle", "mute"])
                            }
                        }
                    }

                    Slider {
                        id: volume

                        objectName: "volume"
                        anchors.verticalCenter: parent.verticalCenter
                        width: volumeHover.hovered || pressed ? 76 : 0
                        visible: width > 0
                        clip: true
                        padding: 6
                        focusPolicy: Qt.NoFocus
                        from: 0
                        to: 150
                        Behavior on width { NumberAnimation { duration: 150 } }
                        Binding on value { when: !volume.pressed; value: volumeControl.shown }
                        onMoved: {
                            mpv.set("volume", value)
                            if (mpv.muted && value > 0)
                                mpv.set("mute", false)
                        }

                        background: Rectangle {
                            x: volume.leftPadding
                            anchors.verticalCenter: parent.verticalCenter
                            width: volume.availableWidth
                            height: 3
                            color: "#40ffffff"

                            Rectangle {
                                width: parent.width * volume.visualPosition
                                height: parent.height
                                color: "white"
                            }

                            Rectangle {
                                x: parent.width * 100 / volume.to - 1
                                width: 2
                                height: parent.height
                                color: "black"
                            }
                        }

                        handle: Rectangle {
                            x: volume.leftPadding + volume.visualPosition * volume.availableWidth - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 12
                            height: 12
                            radius: 6
                            color: "white"
                        }
                    }
                }

                Text {
                    objectName: "clock"
                    Layout.leftMargin: 8
                    text: Words.clock(mpv.position) + " / " + Words.clock(mpv.duration)
                    color: "white"
                    font.family: Tokens.fontSans
                    font.pixelSize: 14
                    font.features: { "tnum": 1 }
                }

                Text {
                    readonly property int chapter: seek.chapterAt(mpv.position)

                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    text: chapter >= 0 ? "· " + seek.chapterLabel(chapter) : ""
                    elide: Text.ElideRight
                    color: "#b3ffffff"
                    font.family: Tokens.fontSans
                    font.pixelSize: 14
                }

                PlayerButton {
                    objectName: "tracksButton"
                    glyph: session.tracks?.subtitlesOn ? "closed_caption" : "closed_caption_outlined"
                    tip: qsTrId("playerSubtitlesShortcut")
                    onClicked: player.toggleMenu("tracks")
                }

                PlayerButton {
                    objectName: "fullscreen"
                    glyph: mpv.fullscreen ? "fullscreen_exit" : "fullscreen"
                    tip: mpv.fullscreen ? qsTrId("playerExitFullscreen") : qsTrId("playerFullscreen")
                    // mpv's `f` and the button toggle the same property.
                    onClicked: mpv.command(["cycle", "fullscreen"])
                }
            }
        }
    }

    // Every menu ends 24 px from the window's right edge, over the bar.
    TracksMenu {
        objectName: "tracksMenu"
        anchors { right: parent.right; rightMargin: 24; bottom: parent.bottom; bottomMargin: 76 }
        visible: player.menu === "tracks"
        tracks: session.tracks
        room: player.height - 92
        onDone: player.menu = ""
        onVisibleChanged: style = false
    }

    component PlayerButton: IconButton {
        implicitWidth: 40
        implicitHeight: 40
        glyphSize: 24
        tone: "white"
        // The keyboard stays with the film.
        focusPolicy: Qt.NoFocus
    }
}
