import QtQuick
import QtTest
import Lumeo

// The player over the fake core with a real libmpv: download d1 streams the
// clip tool/player-test.sh made, 20 s of a test card with a tone.
Item {
    id: root
    width: 1280
    height: 720

    Component {
        id: playerComponent
        Player { anchors.fill: parent }
    }

    Component {
        id: windowComponent
        Main {}
    }

    SignalSpy { id: closed; signalName: "closed" }

    TestCase {
        id: test
        name: "Player"
        when: windowShown

        property var player
        // Where this test's requests start in the fake core's log.
        property int asked

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function asks(line) {
            return requests().some(request => request.startsWith(line))
        }

        function download(fields) {
            const answer = fakeCore.read("download.json")
            answer.id = "d1"
            Object.assign(answer, fields)
            fakeCore.answer("GET", "/api/v1/downloads/d1", 200, answer)
        }

        function start() {
            player = createTemporaryObject(playerComponent, root, { downloadId: "d1", name: "Nosferatu" })
            player.playback.pollInterval = 50
            player.forceActiveFocus()
            closed.target = player
            closed.clear()
        }

        // Playing, its picture on screen.
        function playing() {
            start()
            tryVerify(() => player.mpv.hasPicture, 10000, "a picture")
            tryVerify(() => player.mpv.position > 0.2, 10000, "the film moving")
        }

        function init() {
            asked = fakeCore.requests.length
            download({ ready: true })
            fakeCore.answer("GET", "/api/v1/progress/tt0063350", 200, { entries: [] })
            fakeCore.answer("PUT", "/api/v1/progress/tt0063350", 200, {})
        }

        // mpv blocks on a file the core cannot serve yet and reports a copy
        // that will not play (decisions/player.md).
        function test_aFilmTheCoreCannotServeYetIsNeverHandedToMpv() {
            download({ ready: false, progress: { completed: 0, total: 1000, peers: 3 } })
            start()
            tryVerify(() => requests().filter(r => r.startsWith("GET /api/v1/downloads/d1")).length >= 4)
            verify(!asks("GET /api/v1/downloads/d1/stream"), "mpv was not handed the file")
            tryCompare(findChild(player, "waitLine"), "text", "0% · 3 peers")

            download({ ready: true })
            tryVerify(() => player.mpv.hasPicture, 10000, "the film plays once ready")
        }

        // A stream may drop while it opens, so a failure is tried again for a
        // while before it is said.
        function test_aFilmThatWillNotStartIsReportedInTheEnd() {
            fakeCore.answer("GET", "/api/v1/downloads/d2/stream", 404, { error: "gone" })
            const answer = fakeCore.read("download.json")
            answer.id = "d2"
            answer.ready = true
            fakeCore.answer("GET", "/api/v1/downloads/d2", 200, answer)
            player = createTemporaryObject(playerComponent, root, { downloadId: "d2", name: "Nosferatu" })
            player.playback.pollInterval = 50
            player.playback.reopenStep = 50
            player.playback.openPatience = 500

            tryVerify(() => requests().filter(r => r.startsWith("GET /api/v1/downloads/d2/stream")).length >= 2,
                      10000, "opened again after the first failure")
            tryVerify(() => findChild(player, "failure").visible, 10000, "the failure said")
            compare(findChild(player, "failure").text, "This copy would not start")

            const opens = requests().filter(r => r.startsWith("GET /api/v1/downloads/d2/stream")).length
            const again = findChild(player, "tryAgain")
            // Laid out in its column, so the pointer lands where it is drawn.
            verify(waitForPolish(again.parent))
            mouseClick(again)
            tryVerify(() => requests().filter(r => r.startsWith("GET /api/v1/downloads/d2/stream")).length > opens,
                      10000, "Try again opens it again")
        }

        function test_aFilmGoesOnWhereItWasLeft() {
            fakeCore.answer("GET", "/api/v1/progress/tt0063350", 200,
                            { entries: [{ season: 0, episode: 0, position: 12, duration: 20 }] })
            start()
            tryVerify(() => player.mpv.position >= 12, 10000, "resumed at 12 s")
        }

        function test_aPauseSavesThePosition() {
            playing()
            keyClick(Qt.Key_Space)
            tryVerify(() => player.mpv.paused, 5000, "space pauses")
            tryVerify(() => asks("PUT /api/v1/progress/tt0063350"), 5000, "the position saved")
            const body = JSON.parse(requests().find(r => r.startsWith("PUT /api/v1/progress/"))
                                    .split(" ").slice(2).join(" "))
            verify(body.position > 0 && body.duration > 19, JSON.stringify(body))
        }

        // The keys are mpv's: what they do is read back from mpv.
        function test_theKeysAreMpvs() {
            playing()
            keyClick(Qt.Key_Space)
            tryVerify(() => player.mpv.paused, 5000, "space pauses")
            const at = player.mpv.position
            keyClick(Qt.Key_Right)
            tryVerify(() => Math.abs(player.mpv.position - (at + 5)) < 0.5, 5000,
                      "the arrow seeks the stored step")
            keyClick(Qt.Key_M)
            tryVerify(() => player.mpv.muted, 5000, "m mutes")
            keyClick(Qt.Key_Q)
            tryCompare(closed, "count", 1, 5000, "q leaves")
        }

        function test_escLeavesFullscreenFirstThenTheFilm() {
            playing()
            player.mpv.set("fullscreen", true)
            tryVerify(() => player.mpv.fullscreen)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !player.mpv.fullscreen, 5000, "Esc leaves fullscreen")
            compare(closed.count, 0)
            keyClick(Qt.Key_Escape)
            tryCompare(closed, "count", 1, 5000, "the second Esc leaves the film")
        }

        // A click goes to mpv as its button, and mpv's binding pauses; the
        // wheel is mpv's over the picture and nobody's over the bar.
        function test_theMouseIsMpvsOverThePicture() {
            playing()
            mouseClick(player, player.width / 2, player.height / 2)
            tryVerify(() => player.mpv.paused, 5000, "a click pauses")
            player.mpv.set("volume", 50)
            tryCompare(player.mpv, "volume", 50)
            mouseWheel(player, player.width / 2, player.height / 2, 0, 120)
            tryVerify(() => player.mpv.volume > 50, 5000, "the wheel turns it up")

            const bar = findChild(player, "clock")
            const volume = player.mpv.volume
            mouseMove(player, player.width / 2, player.height - 30)
            mouseWheel(bar, 4, 4, 0, 120)
            // mpv answered the first wheel within this.
            wait(200)
            compare(player.mpv.volume, volume, "the bar keeps the wheel")

            mouseClick(player, player.width / 2, player.height / 2)
            tryVerify(() => !player.mpv.paused, 5000, "a click plays")
            // Between the clock and the buttons: the bar, not the picture.
            mouseClick(bar, bar.width + 100, bar.height / 2)
            wait(200)
            verify(!player.mpv.paused, "a click on the bar is not a pause")
        }

        function test_aClickOnTheSeekBarSeeksThere() {
            playing()
            const bar = findChild(player, "seekBar")
            keyClick(Qt.Key_Space)
            tryVerify(() => player.mpv.paused)
            mouseMove(player, player.width / 2, player.height - 30)
            mouseMove(bar, bar.width * 0.75, bar.height / 2)
            compare(findChild(bar, "pointedTime").children[0].text, "0:15", "the time it would seek to")
            mouseClick(bar, bar.width * 0.75, bar.height / 2)
            tryVerify(() => Math.abs(player.mpv.position - 15) < 0.5, 5000, "sought to three quarters")
            verify(player.mpv.paused, "still paused")
        }

        function test_theVolumeIsKeptForTheNextFilm() {
            playing()
            keyClick(Qt.Key_9)
            tryVerify(() => player.mpv.volume < 100, 5000, "9 turns it down")
            const volume = player.mpv.volume
            tryCompare(LocalSettings, "volume", volume)
            player.destroy()
            start()
            tryCompare(player.mpv, "volume", volume, 5000)
        }

        function test_mpvQuittingClosesThePlayer() {
            playing()
            player.mpv.command(["quit"])
            tryCompare(closed, "count", 1, 5000)
        }

        // A film takes the screen when it starts, and closing it gives the
        // window back as it was (decisions/player.md).
        function test_aFilmTakesTheScreenAndGivesItBack() {
            const win = createTemporaryObject(windowComponent, null, { toOpen: "" })
            tryVerify(() => win.visible, 5000, "the window up")
            compare(win.visibility, Window.Windowed)
            win.play("d1", "Nosferatu", true)
            tryVerify(() => win.visibility === Window.FullScreen, 5000, "the film takes the screen")
            tryVerify(() => win.player.mpv.hasPicture, 10000)
            win.player.close()
            tryVerify(() => win.visibility === Window.Windowed, 5000, "the window given back")
            tryVerify(() => win.player === null, 5000, "the player gone")
        }

        // A window made fullscreen with F11 is fullscreen again after the film,
        // and the film's own `f` leaves fullscreen for a window, not for it.
        function test_aFilmGivesBackAFullscreenWindow() {
            const win = createTemporaryObject(windowComponent, null, { toOpen: "" })
            tryVerify(() => win.visible, 5000)
            win.visibility = Window.FullScreen
            tryVerify(() => win.visibility === Window.FullScreen, 5000)
            win.play("d1", "Nosferatu", true)
            tryVerify(() => win.player.mpv.hasPicture, 10000)
            win.player.mpv.set("fullscreen", false)
            tryVerify(() => win.visibility === Window.Windowed, 5000, "f leaves fullscreen")
            win.player.close()
            tryVerify(() => win.visibility === Window.FullScreen, 5000, "the window given back fullscreen")
        }

        // Another copy or episode in the same sitting keeps the window as it
        // is; the one before goes, its position saved.
        function test_theNextDownloadTakesTheWindowInTheSameSitting() {
            const win = createTemporaryObject(windowComponent, null, { toOpen: "" })
            tryVerify(() => win.visible, 5000)
            win.play("d1", "Nosferatu", true)
            tryVerify(() => win.visibility === Window.FullScreen, 5000)
            tryVerify(() => win.player.mpv.position > 1, 10000)
            const first = win.player
            first.next("d1", "Nosferatu")
            verify(win.player !== first)
            tryVerify(() => win.player.mpv.hasPicture, 10000, "the next one plays")
            compare(win.visibility, Window.FullScreen)
            tryVerify(() => asks("PUT /api/v1/progress/tt0063350"), 5000, "the first one's position saved")
            win.player.close()
            tryVerify(() => win.visibility === Window.Windowed, 5000, "the window given back as it was")
        }

        // Closing the window ends the process: the position is saved while
        // the core still answers, and mpv goes before the window does.
        function test_closingTheWindowMidFilmSavesThePosition() {
            const win = createTemporaryObject(windowComponent, null, { toOpen: "" })
            tryVerify(() => win.visible, 5000)
            win.play("d1", "Nosferatu", true)
            tryVerify(() => !!win.player && win.player.mpv.position > 1, 10000, "the film playing")
            win.close()
            tryVerify(() => !win.visible, 5000, "the window closed")
            verify(asks("PUT /api/v1/progress/tt0063350"), "the position saved first")
            compare(win.player, null)
        }
    }
}
