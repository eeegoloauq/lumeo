import QtQuick
import QtTest
import Lumeo

// The gear's pages over a real mpv: d1 is the test card, in two chapters,
// Intro and Story.
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
        name: "Gear"
        when: windowShown

        property var player
        property int asked
        readonly property string item: "tt0063350"

        readonly property var playing: ({
            providerId: "torrentio",
            rawName: "Night of the Living Dead 1968 1080p BluRay x264 AC3",
            release: { resolution: "1080p", source: "BluRay", group: "GROUP" },
            locator: { scheme: "torrent", infoHash: "abc", fileIndex: 0 },
        })
        readonly property var other: ({
            providerId: "torrentio",
            rawName: "Night of the Living Dead 1968 720p WEB x264",
            release: { resolution: "720p", source: "WEB", group: "OTHER" },
            size: 1073741824,
            seeders: 40,
            locator: { scheme: "torrent", infoHash: "def", fileIndex: 0 },
        })

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function menu() {
            return findChild(player, "settingsMenu")
        }

        function click(name) {
            const target = findChild(menu(), name)
            verify(!!target && target.visible, name + " on show")
            mouseClick(target)
        }

        function start(fields) {
            const download = fakeCore.read("download.json")
            Object.assign(download, { id: "d1", ready: true }, fields ?? {})
            fakeCore.answer("GET", "/api/v1/downloads/d1", 200, download)
            player = createTemporaryObject(playerComponent, root, { downloadId: "d1", name: "Night of the Living Dead" })
            player.forceActiveFocus()
            next.target = player
            next.clear()
        }

        function playing_() {
            start()
            tryVerify(() => player.mpv.hasPicture && player.mpv.chapters.length === 2, 10000, "playing")
        }

        // Opened, and laid out before anything in it is clicked.
        function openGear() {
            mouseMove(player, player.width / 2, player.height - 30)
            mouseClick(findChild(player, "settingsButton"))
            tryVerify(() => menu().visible)
            verify(waitForRendering(menu()))
        }

        function page(name) {
            click("page-" + name)
            tryCompare(menu(), "page", name)
            verify(waitForRendering(menu()))
        }

        function init() {
            failOnWarning(/mpv refused/)
            asked = fakeCore.requests.length
            fakeCore.answer("GET", "/api/v1/progress/" + item, 200, { entries: [] })
            fakeCore.answer("PUT", "/api/v1/progress/" + item, 200, {})
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [playing, other], providers: 1 })
            fakeCore.answer("PATCH", "/api/v1/choices/" + item, 200, {})
            fakeCore.answer("POST", "/api/v1/downloads", 201, { id: "d9", itemId: item, state: "active" })
        }

        // For this film only: nothing is sent to be kept.
        function test_speedIsMpvsAndKeptNowhere() {
            playing_()
            openGear()
            page("speed")
            click("speed-1.5")
            tryCompare(player.mpv, "speed", 1.5)
            verify(!requests().some(r => r.startsWith("PATCH /api/v1/preferences")))
        }

        function test_thePictureIsFittedAndSharpenedByMpv() {
            playing_()
            openGear()
            page("picture")
            click("fit-1")
            tryCompare(player.mpv, "fit", 1)
            click("fit-2")
            tryCompare(player.mpv, "fit", 2)
            click("anime4k-a")
            tryCompare(player.mpv, "anime4k", "a")
            click("anime4k-off")
            tryCompare(player.mpv, "anime4k", "")
        }

        function test_aChapterIsJumpedTo() {
            playing_()
            openGear()
            compare(findChild(menu(), "page-chapters").detail, "Intro")
            page("chapters")
            click("chapter-1")
            tryCompare(player.mpv, "chapter", 1)
            verify(player.mpv.position >= 5)
        }

        function test_decodingGoesToSoftware() {
            playing_()
            openGear()
            page("decoding")
            click("software")
            tryCompare(player.mpv, "hwdec", "no")
        }

        // A copy picked here is the title's release, as in the title page's
        // drawer, and the player goes on with its download.
        function test_theSourcePageSwitchesCopies() {
            playing_()
            openGear()
            tryVerify(() => findChild(menu(), "page-source").detail === "1080p · GROUP · BluRay", 5000,
                      "the copy playing named")
            page("source")
            tryVerify(() => !!findChild(menu(), "copy-1"))
            verify(findChild(menu(), "copy-0").current)
            click("copy-1")
            tryVerify(() => requests().some(r => r.startsWith("PATCH /api/v1/choices/" + item) && r.includes("720p WEB")))
            tryCompare(next, "count", 1, 5000)
            compare(next.signalArguments[0][0], "d9")
            tryVerify(() => player.mpv.paused, 5000, "this copy paused while the other starts")
        }

        // A copy finding no peers for half a minute offers the next one.
        function test_aCopyThatFindsNoPeersOffersTheNextOne() {
            start({
                ready: false,
                resolved: false,
                progress: { completed: 0, total: 1000, peers: 0 },
                waitingSince: new Date(Date.now() - 31000).toISOString(),
            })
            const offer = () => findChild(player, "anotherCopy")
            tryVerify(() => offer()?.visible, 5000, "another copy offered")
            mouseClick(offer())
            tryCompare(next, "count", 1, 5000)
            compare(next.signalArguments[0][0], "d9")
        }

        function test_noOtherCopyIsOfferedBeforeTheWaitRunsLong() {
            start({
                ready: false,
                resolved: false,
                progress: { completed: 0, total: 1000, peers: 0 },
                waitingSince: new Date(Date.now() - 5000).toISOString(),
            })
            tryVerify(() => requests().filter(r => r.startsWith("GET /api/v1/downloads/d1")).length >= 1)
            wait(100)
            verify(!findChild(player, "anotherCopy").visible)
            verify(!requests().some(r => r.startsWith("GET /api/v1/sources")), "nobody asked for copies")
        }
    }
}
