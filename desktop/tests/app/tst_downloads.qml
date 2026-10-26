import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }
    SignalSpy { id: watched; signalName: "watch" }

    TestCase {
        name: "Downloads"
        when: windowShown

        property var shell
        property int asked
        readonly property string show: "tt0903747"
        readonly property string film: "tt0063350"

        function download(id, fields) {
            return Object.assign({}, fakeCore.read("download.json"),
                                 { id: id, transfer: "torrent:" + id, updatedAt: new Date().toISOString() }, fields)
        }

        function episode(id, state, season, number, fields) {
            return download(id, Object.assign({ itemId: show, state: state, season: season, episode: number,
                                                transfer: "torrent:pack" }, fields))
        }

        function serve(downloads) {
            fakeCore.answer("GET", "/api/v1/downloads", 200, { downloads: downloads })
            Downloads.refresh()
        }

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function init() {
            for (const item of fakeCore.read("items.json"))
                fakeCore.answer("GET", "/api/v1/items/" + item.id, 200, item)
            fakeCore.answer("GET", "/api/v1/progress/" + show, 200, { entries: [], next: { season: 1, episode: 10 } })
            fakeCore.answer("GET", "/api/v1/storage", 200, { used: 200e9, disk: { total: 1000e9, free: 300e9 }, cache: 0, titles: [] })
            fakeCore.answer("PATCH", "/api/v1/downloads/arriving", 200, download("arriving", { state: "paused", pausedByUser: true }))
            fakeCore.answer("DELETE", "/api/v1/downloads/paused", 204)
            serve([
                episode("s1e10", "done", 1, 10), episode("s1e9", "done", 1, 9), episode("s2e1", "done", 2, 1),
                download("film", { state: "done", itemId: film, release: { resolution: "1080p", hdr: ["DV"] } }),
                download("arriving", { itemId: "tt0110912" }),
                episode("paused", "paused", 3, 1, { pausedByUser: true, progress: { completed: 1, total: 4 } }),
                // None of these is the panel's: finished two days ago, paused
                // by a core that stopped, and a file of this machine's.
                download("old", { state: "done", itemId: film, updatedAt: new Date(Date.now() - 2 * 86400e3).toISOString() }),
                download("stopped", { state: "paused" }),
                download("local", { state: "done", locator: { scheme: "file" } }),
            ])
            shell = createTemporaryObject(shellComponent, window)
            watched.target = shell
            watched.clear()
            tryVerify(() => findChild(shell, "downloads")?.list.ring === "arriving", 5000, "the ring")
            asked = fakeCore.requests.length
            mouseClick(findChild(shell, "downloads"))
            tryVerify(() => findChild(shell, "downloadsPanel").opened)
        }

        function row(key) {
            return findChild(findChild(shell, "downloadsPanel").contentItem, "download-" + key)
        }

        function shown(key) {
            const found = row(key)
            return found && found.visible ? found : null
        }

        function test_aTitleIsOneRowUnderWhatCanBeDoneAndPlaysTheEpisodeNext() {
            tryVerify(() => !!shown("0:" + show), 5000, "the series on disk")
            const panel = findChild(shell, "downloadsPanel")
            const order = ["section:ready", "download-0:" + show, "download-one:film", "section:arriving",
                           "download-one:arriving", "section:waiting", "download-3:" + show]
            const ys = order.map(name => findChild(panel.contentItem, name).y)
            compare(ys.slice().sort((a, b) => a - b), ys, "in the order of what can be done")
            compare(findChild(findChild(panel.contentItem, "section:ready"), "count").text, "4")
            compare(findChild(row("0:" + show), "tag").text, "S1 E9–E10, S2 E1")
            compare(findChild(row("one:film"), "tag").text, "1080p DV")
            tryVerify(() => row("0:" + show).title === "Breaking Bad", 5000, "the catalogue's name")
            // The core's next episode, once it says which.
            tryVerify(() => findChild(row("0:" + show), "line").text.startsWith("Next: S1 E10 · "))

            mouseClick(findChild(row("0:" + show), "play"))
            compare(watched.count, 1)
            compare(watched.signalArguments[0][0], "s1e10")
            compare(watched.signalArguments[0][1], "Breaking Bad · S01E10")
            verify(!panel.opened)
        }

        function test_aSeriesOpensIntoItsEpisodesAndEachActsAlone() {
            tryVerify(() => !!shown("0:" + show))
            verify(!shown("s1e9"))
            mouseClick(row("0:" + show))
            tryVerify(() => !!shown("s1e9") && !!shown("s2e1"))
            // An episode on disk plays from the row itself.
            mouseClick(row("s2e1"))
            compare(watched.signalArguments[0][0], "s2e1")
        }

        function test_arrivingIsPausedAndWaitingIsStoppedWithItsData() {
            tryVerify(() => !!shown("one:arriving") && !!shown("3:" + show))
            mouseClick(findChild(row("one:arriving"), "pause"))
            tryVerify(() => requests().includes('PATCH /api/v1/downloads/arriving {"paused":true}'))
            verify(!findChild(row("3:" + show), "pause").visible, "nothing flows there to pause")

            mouseClick(findChild(row("3:" + show), "stop"))
            tryVerify(() => requests().includes("DELETE /api/v1/downloads/paused?data=true"))
            verify(!shown("3:" + show), "gone at once")
        }

        function test_clearTakesWhatFinishedOutAndTheRestStays() {
            tryVerify(() => !!shown("one:film"))
            mouseClick(findChild(findChild(shell, "downloadsPanel").contentItem, "downloadsClear"))
            tryVerify(() => !shown("one:film") && !shown("0:" + show))
            verify(!!shown("one:arriving"))
        }

        function test_atRestTheArrowStaysAndStorageIsAClickAway() {
            serve([])
            tryCompare(findChild(shell, "downloads").list, "ring", "rest")
            tryVerify(() => findChild(findChild(shell, "downloadsPanel").contentItem, "downloadsNothing").visible)
            mouseClick(findChild(findChild(shell, "downloadsPanel").contentItem, "downloadsStorage"))
            tryCompare(shell, "page", "settings")
        }
    }
}
