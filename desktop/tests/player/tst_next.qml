import QtQuick
import QtTest
import Lumeo

// What comes after an episode, over a real mpv: e1 is an episode whose last
// six seconds are a chapter named Ending; d1 is a test card whose chapters
// are Intro and Story, and names no ending.
Item {
    id: root
    width: 1280
    height: 720

    Component {
        id: playerComponent
        Player { anchors.fill: parent }
    }

    SignalSpy { id: next; signalName: "next" }

    TestCase {
        name: "Next"
        when: windowShown

        property var player
        property int asked
        readonly property string item: "tt0052520"

        readonly property var episodes: [
            { season: 1, number: 1, title: "Where Is Everybody?" },
            { season: 1, number: 2, title: "One for the Angels" },
            { season: 1, number: 3, title: "Mr. Denton on Doomsday", released: "2099-01-01T00:00:00Z" },
        ]
        readonly property var copy: ({
            providerId: "torrentio",
            rawName: "The Twilight Zone S01E02 1080p BluRay",
            release: { resolution: "1080p", source: "BluRay" },
            locator: { scheme: "torrent", infoHash: "e2", fileIndex: 0 },
        })

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function bodies(line) {
            return requests().filter(r => r.startsWith(line)).map(r => JSON.parse(r.slice(line.length + 1)))
        }

        function start(id, fields) {
            const download = fakeCore.read("download.json")
            Object.assign(download, { id: id, itemId: item, season: 1, episode: 1, state: "done", ready: true,
                                      name: "The Twilight Zone S01E01" }, fields ?? {})
            fakeCore.answer("GET", "/api/v1/downloads/" + id, 200, download)
            fakeCore.answer("GET", "/api/v1/downloads/" + id + "/subtitles", 200, { subtitles: [] })
            player = createTemporaryObject(playerComponent, root, { downloadId: id, name: "The Twilight Zone" })
            player.playback.pollInterval = 50
            player.playback.next.second = 50
            player.playback.next.prefetchRetry = 100
            player.forceActiveFocus()
            next.target = player
            next.clear()
        }

        function playing(id, fields) {
            start(id, fields)
            tryVerify(() => player.mpv.hasPicture && player.mpv.chapters.length === 2, 10000, "playing")
            tryVerify(() => !!player.playback.next.episode.number, 5000, "the next episode known")
        }

        function seek(seconds) {
            player.mpv.command(["seek", String(seconds), "absolute+exact"])
            tryVerify(() => Math.abs(player.mpv.position - seconds) < 1, 5000, "at " + seconds)
        }

        function init() {
            failOnWarning(/mpv refused/)
            asked = fakeCore.requests.length
            fakeCore.answer("GET", "/api/v1/items/" + item, 200,
                            { id: item, kind: "series", title: "The Twilight Zone", runtime: "25 min", episodes: episodes })
            fakeCore.answer("GET", "/api/v1/items/" + item + "/after", 200, { next: episodes[1] })
            fakeCore.answer("GET", "/api/v1/progress/" + item, 200, { entries: [] })
            fakeCore.answer("PUT", "/api/v1/progress/" + item, 200, {})
            fakeCore.answer("GET", "/api/v1/choices/" + item, 200, {})
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy], providers: 1 })
            fakeCore.answer("POST", "/api/v1/downloads", 201,
                            { id: "e2", itemId: item, season: 1, episode: 2, state: "active" })
        }

        // Once this one is on disk, the copy Play would start for the next
        // one starts downloading, as a prefetch the core may refuse.
        function test_anEpisodeOnDiskStartsTheNextOneDownloading() {
            start("e1")
            tryVerify(() => bodies("POST /api/v1/downloads").length === 1, 10000, "the next one asked for")
            const body = bodies("POST /api/v1/downloads")[0]
            compare(body.episode, 2)
            compare(body.prefetch, true)
        }

        function test_anEpisodeStillArrivingFetchesNothingAhead() {
            playing("e1", { state: "active" })
            wait(200)
            compare(bodies("POST /api/v1/downloads").length, 0)
        }

        // A refusal for room is an answer, not a failure: the panel offers
        // the download anyway.
        function test_aPrefetchTheCoreHasNoRoomForCanBeDownloadedAnyway() {
            fakeCore.answer("POST", "/api/v1/downloads", 507, { error: "no room" })
            playing("e1")
            tryCompare(player.playback.next, "fetch", Next.NoRoom, 5000)
            mouseMove(player, player.width / 2, player.height - 30)
            mouseClick(findChild(player, "downloadButton"))
            const panel = findChild(player, "downloadPanel")
            tryVerify(() => panel.visible)
            verify(waitForRendering(panel))
            const anyway = findChild(panel, "downloadNext")
            compare(anyway.label, "Download anyway")
            fakeCore.answer("POST", "/api/v1/downloads", 201,
                            { id: "e2", itemId: item, season: 1, episode: 2, state: "active" })
            mouseClick(anyway)
            tryVerify(() => bodies("POST /api/v1/downloads").length === 2, 5000)
            verify(bodies("POST /api/v1/downloads")[1].prefetch === undefined, "without the disk-limit check")
        }

        // No provider answering is the network, not an answer: asked again.
        function test_aPrefetchNoProviderAnsweredIsAskedForAgain() {
            fakeCore.answer("GET", "/api/v1/sources", 200,
                            { sources: [], providers: 1, failed: [{ provider: "torrentio", status: 0 }] })
            playing("e1")
            tryCompare(player.playback.next, "fetch", Next.Failed, 5000)
            const asks = requests().filter(r => r.startsWith("GET /api/v1/sources")).length
            tryVerify(() => requests().filter(r => r.startsWith("GET /api/v1/sources")).length > asks, 5000,
                      "asked again")
        }

        // The named ending offers the next episode, counting down to the end.
        function test_theNextEpisodeIsOfferedOverTheCredits() {
            playing("e1", { state: "active" })
            verify(!findChild(player, "nextCard").visible)
            seek(15)
            tryVerify(() => findChild(player, "nextCard").visible, 5000)
            verify(player.playback.next.secondsLeft >= 0, "it counts down")
        }

        // An anime's ending can start before the core's 90%.
        function test_anEpisodeIsWatchedOnceItsNamedEndingStarts() {
            playing("e1", { state: "active" })
            seek(15)
            keyClick(Qt.Key_Space)
            tryVerify(() => bodies("PUT /api/v1/progress/" + item).some(b => b.watched === true), 5000)
        }

        // At the end of a named ending the next one starts at once, this one
        // saved as watched first.
        function test_anEpisodeThatRunsOutStartsTheNext() {
            playing("e1", { state: "active" })
            seek(19)
            tryCompare(next, "count", 1, 10000)
            compare(next.signalArguments[0][0], "e2")
            verify(bodies("PUT /api/v1/progress/" + item).some(b => b.watched === true))
        }

        // A file that names no ending holds its last frame and counts down.
        function test_anUnnamedEndHoldsItsLastFrameAndCountsDown() {
            playing("d1", { state: "active" })
            seek(19.5)
            tryVerify(() => findChild(player, "nextCard").visible, 10000, "the card over the last frame")
            tryCompare(next, "count", 1, 5000)
            compare(next.signalArguments[0][0], "e2")
        }

        function test_theOpeningIsSkipped() {
            playing("d1", { state: "active" })
            seek(1)
            const skip = findChild(player, "skipButton")
            tryVerify(() => skip.visible, 5000)
            compare(skip.text, "Skip opening")
            mouseClick(skip)
            tryVerify(() => player.mpv.position >= 5, 5000, "past the opening")
            tryVerify(() => !skip.visible)
        }

        function test_theEpisodesPanelStartsAReleasedEpisode() {
            playing("e1", { state: "active" })
            mouseMove(player, player.width / 2, player.height - 30)
            mouseClick(findChild(player, "episodesButton"))
            const panel = findChild(player, "episodesPanel")
            tryVerify(() => panel.visible && !!findChild(panel, "episode-1-2"))
            verify(waitForRendering(panel))
            verify(!findChild(panel, "episode-1-3").enabled, "not out yet")
            verify(!findChild(panel, "episode-1-1").enabled, "the one playing")
            mouseClick(findChild(panel, "episode-1-2"))
            tryCompare(next, "count", 1, 5000)
            compare(next.signalArguments[0][0], "e2")
        }
    }
}
