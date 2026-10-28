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
    SignalSpy { id: fullscreenAsked; signalName: "fullscreenAsked" }

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
            fullscreenAsked.target = player
            fullscreenAsked.clear()
            player.fullscreen = true
            keyClick(Qt.Key_Escape)
            tryCompare(fullscreenAsked, "count", 1, 5000, "Esc leaves fullscreen")
            compare(fullscreenAsked.signalArguments[0][0], false)
            compare(closed.count, 0)
            player.fullscreen = false
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
            mouseMove(bar, bar.width / 2, bar.height / 2)
            compare(findChild(bar, "pointedTime").children[0].text, "0:11", "the time it would seek to")
            mouseClick(bar, bar.width / 2, bar.height / 2)
            tryVerify(() => Math.abs(player.mpv.position - 11) < 0.5, 5000, "sought to the middle")
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

        // A dropped stream from the core resumes rather than ending the film.
        function test_theCoresStreamReconnects() {
            playing()
            let lavf = null
            player.mpv.get("stream-lavf-o", value => lavf = value)
            tryVerify(() => lavf !== null, 5000)
            compare(lavf.reconnect, "1")
        }

        function test_mpvQuittingClosesThePlayer() {
            playing()
            player.mpv.command(["quit"])
            tryCompare(closed, "count", 1, 5000)
        }

        // Trailers are their links played in order as they are, nothing
        // about them asked of the core or kept, nor the core's reconnects;
        // one that will not open is dropped for the next, and the page told;
        // their Play leaves them for the title's own.
        function test_trailersPlayTheirLinksAndLeaveForTheTitle() {
            let played = 0
            const failed = []
            const missing = fakeCore.address + "/no-such-trailer"
            player = createTemporaryObject(playerComponent, root, {
                downloadId: "", name: "Nosferatu",
                trailer: { urls: [missing, fakeCore.address + "/trailer", fakeCore.address + "/trailer?second"],
                           play: "Play", played: () => ++played, failed: url => failed.push(url) } })
            closed.target = player
            closed.clear()
            tryVerify(() => player.mpv.hasPicture, 10000, "a picture")
            compare(failed, [missing])
            compare(player.playback.trailers.length, 2)
            compare(player.playback.failure, Playback.None)
            let lavf = null
            player.mpv.get("stream-lavf-o", value => lavf = value)
            tryVerify(() => lavf !== null, 5000)
            compare(Object.keys(lavf).length, 0, JSON.stringify(lavf))
            // The yt-dlp the app found is the one mpv runs.
            let opts = null
            player.mpv.get("script-opts", value => opts = value)
            tryVerify(() => opts !== null, 5000)
            compare(opts["ytdl_hook-ytdl_path"] ?? "", MpvFacts.ytdlPath())
            mouseMove(player, 640, 360)
            const next = findChild(player, "nextButton")
            const previous = findChild(player, "previousButton")
            verify(next.visible, "a second trailer to go to")
            verify(!previous.visible, "none before the first")
            mouseClick(next)
            tryCompare(player.playback, "trailer", 1, 5000)
            verify(!next.visible, "the last one")
            verify(previous.visible, "the first to go back to")
            // The list is the episodes' panel, the trailers numbered.
            mouseClick(findChild(player, "episodesButton"))
            const first = findChild(player, "episode-0-1")
            verify(first, "the first trailer listed")
            verify(!findChild(player, "episode-0-3"), "the one that failed left out")
            mouseClick(first)
            tryCompare(player.playback, "trailer", 0, 5000)
            // Its end goes on to the next. A seek while the file is still
            // being opened is dropped, so it is asked until it lands, a
            // second before the end.
            tryVerify(() => {
                if (player.mpv.duration > 0 && player.mpv.position > player.mpv.duration - 2)
                    return true
                player.mpv.command(["seek", "-1", "absolute"])
                return false
            }, 5000, "near the end")
            tryCompare(player.playback, "trailer", 1, 5000)
            // The bar hid while it played.
            mouseMove(player, 600, 300)
            const play = findChild(player, "trailerPlay")
            tryVerify(() => play.visible, 5000, "the bar back")
            verify(waitForPolish(play.parent))
            mouseClick(play)
            tryCompare(closed, "count", 1, 5000)
            compare(played, 1)
            // What a trailer would ask names no download. A request for one is
            // the last test's player's, which can still be on its way.
            verify(!requests().some(r => /^\w+ \/api\/v1\/(downloads|progress)\/($|[\/? ])/.test(r)),
                   requests().join("\n"))
        }

        // Every trailer failing is the failure, and only then.
        function test_noTrailerOpening() {
            player = createTemporaryObject(playerComponent, root, {
                downloadId: "", name: "Nosferatu",
                trailer: { urls: [fakeCore.address + "/no-such-trailer", fakeCore.address + "/nor-this"] } })
            tryCompare(player.playback, "failure", Playback.WouldNotStart, 10000)
            compare(player.playback.trailers.length, 0)
            verify(!player.playback.refused, "nothing YouTube said")
        }

        // A title's page plays its trailer in the banner, muted, a moment
        // after it is up, past one that will not open, which the Trailer
        // button then leaves out; the player goes on from the same second,
        // and over the page ends it for good.
        function test_theBannerPlaysTheTrailerUntilThePlayerTakesIt() {
            const film = { id: "tt0063350", kind: "movie", title: "Nosferatu", year: 1922,
                           trailers: [fakeCore.address + "/no-such-trailer", fakeCore.address + "/trailer"] }
            fakeCore.answer("GET", "/api/v1/items/tt0063350", 200, film)
            const ytdl = MpvFacts.ytdl
            MpvFacts.ytdl = true
            const win = createTemporaryObject(windowComponent, null)
            tryVerify(() => win.visible, 5000)
            Opening.title(film)
            let page = null
            tryVerify(() => (page = findChild(win.contentItem, "title")) !== null, 5000, "the title page")
            page.previewDelay = 50
            let clip = null
            tryVerify(() => (clip = findChild(page, "trailerPreview"))?.hasPicture, 10000, "the trailer in the banner")
            verify(clip.muted)
            tryCompare(clip, "fit", 1, 5000, "filling the banner")
            compare(page.trailerUrls, [fakeCore.address + "/trailer"])
            mouseClick(findChild(page, "trailerSound"))
            tryVerify(() => !clip.muted, 5000, "sound on")

            tryVerify(() => clip.position > 0.2, 5000)
            mouseClick(findChild(page, "trailerFullscreen"))
            tryVerify(() => !!win.player, 5000, "the player")
            verify(win.player.trailer.start > 0.2, "from the banner's second")
            compare(win.player.trailer.urls, [fakeCore.address + "/trailer"])
            tryVerify(() => !findChild(page, "trailerPreview"), 5000, "gone under the player")
            let start = null
            win.player.mpv.get("start", value => start = value)
            tryVerify(() => start !== null, 5000)
            verify(start !== "none", start)
            tryVerify(() => win.player.mpv.hasPicture, 10000)
            win.player.close()
            tryVerify(() => page.visible, 5000)
            wait(150)
            verify(!findChild(page, "trailerPreview"), "not back after the film")
            MpvFacts.ytdl = ytdl
        }

        // An upright trailer plays in the banner whole: filling it would
        // leave a sliver.
        function test_anUprightTrailerPlaysWholeInTheBanner() {
            const film = { id: "tt0063350", kind: "movie", title: "Nosferatu", year: 1922,
                           trailers: [fakeCore.address + "/trailer-upright"] }
            fakeCore.answer("GET", "/api/v1/items/tt0063350", 200, film)
            const ytdl = MpvFacts.ytdl
            MpvFacts.ytdl = true
            const win = createTemporaryObject(windowComponent, null)
            tryVerify(() => win.visible, 5000)
            Opening.title(film)
            let page = null
            tryVerify(() => (page = findChild(win.contentItem, "title")) !== null, 5000, "the title page")
            page.previewDelay = 50
            let clip = null
            tryVerify(() => (clip = findChild(page, "trailerPreview"))?.hasPicture, 10000, "the trailer in the banner")
            tryCompare(clip, "fit", 0, 5000, "fitted, not filling")
            MpvFacts.ytdl = ytdl
        }

        // A film takes the screen when it starts, and closing it gives the
        // window back as it was (decisions/player.md).
        function test_aFilmTakesTheScreenAndGivesItBack() {
            const win = createTemporaryObject(windowComponent, null)
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
            const win = createTemporaryObject(windowComponent, null)
            tryVerify(() => win.visible, 5000)
            win.visibility = Window.FullScreen
            tryVerify(() => win.visibility === Window.FullScreen, 5000)
            win.play("d1", "Nosferatu", true)
            tryVerify(() => win.player.mpv.hasPicture, 10000)
            // The key through mpv's input, as a press reaches it.
            win.player.mpv.command(["keypress", "f"])
            tryVerify(() => win.visibility === Window.Windowed, 5000, "f leaves fullscreen")
            win.player.close()
            tryVerify(() => win.visibility === Window.FullScreen, 5000, "the window given back fullscreen")
        }

        // Another copy or episode in the same sitting keeps the window as it
        // is; the one before goes, its position saved.
        function test_theNextDownloadTakesTheWindowInTheSameSitting() {
            const win = createTemporaryObject(windowComponent, null)
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
            const win = createTemporaryObject(windowComponent, null)
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
