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
        name: "Title"
        when: windowShown

        property var shell

        readonly property var copy: ({
            providerId: "torrentio",
            rawName: "Nosferatu 1922 1080p BluRay x264",
            release: { resolution: "1080p", source: "BluRay", group: "GROUP" },
            locator: { scheme: "torrent", infoHash: "abc", fileIndex: 0 },
        })

        function init() {
            const items = []
            for (let i = 0; i < 3; ++i) {
                const film = { id: "tt" + (2000 + i), kind: "movie", title: "Film " + i, year: 1920 + i }
                items.push(film)
                fakeCore.answer("GET", "/api/v1/items/" + film.id, 200, film)
                fakeCore.answer("GET", "/api/v1/progress/" + film.id, 200, {})
            }
            fakeCore.answer("GET", "/api/v1/catalog", 200, { items: items })
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy], providers: 1 })
            fakeCore.answer("POST", "/api/v1/downloads", 201, { id: "d1", itemId: "tt2001", state: "active" })
            shell = createTemporaryObject(shellComponent, window)
            watched.clear()
            watched.target = shell
            tryVerify(() => findChild(shell, "play") !== null, 5000, "the hero")
            waitForRendering(shell)
        }

        // Play in the banner opened the title without starting it, and later
        // started it without a download behind it.
        function test_playInTheBannerStartsTheTitle() {
            mouseClick(findChild(shell, "play"))
            compare(shell.page, "title")
            watched.wait(5000)
            compare(watched.signalArguments[0][0], "d1")
        }

        function test_moreInfoOpensTheTitleAndStartsNothing() {
            mouseClick(findChild(shell, "moreInfo"))
            compare(shell.page, "title")
            tryVerify(() => findChild(shell, "titlePlay")?.enabled, 5000, "the copies listed")
            wait(50)
            compare(watched.count, 0)
            verify(!fakeCore.requests.some(r => r.startsWith("POST /api/v1/downloads")))
        }

        // None ships with the app: the empty list is the way to add one.
        function test_noSourceAddonLeadsToTheSettings() {
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [], providers: 0 })
            mouseClick(findChild(shell, "moreInfo"))
            const add = findChild(shell, "playLineAction")
            tryVerify(() => add.visible, 5000, "Add one")
            // Placed in its row, so the pointer lands on it.
            verify(waitForPolish(add.parent))
            mouseClick(add)
            compare(shell.page, "settings")
        }
    }
}
