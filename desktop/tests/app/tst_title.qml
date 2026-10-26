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
        // Where this test's requests start in the fake core's log.
        property int asked

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        readonly property var copy: ({
            providerId: "torrentio",
            rawName: "Nosferatu 1922 1080p BluRay x264",
            release: { resolution: "1080p", source: "BluRay", group: "GROUP" },
            locator: { scheme: "torrent", infoHash: "abc", fileIndex: 0 },
        })
        readonly property var other: ({
            providerId: "torrentio",
            rawName: "Nosferatu 1922 720p WEB x264",
            release: { resolution: "720p", source: "WEB", group: "OTHER" },
            locator: { scheme: "torrent", infoHash: "def", fileIndex: 0 },
        })

        function cleanup() {
            if (Preferences.current.askCopy) {
                const prefs = fakeCore.read("preferences.json")
                fakeCore.answer("PATCH", "/api/v1/preferences", 200, prefs)
                Preferences.patch({ askCopy: false })
                tryVerify(() => !Preferences.current.askCopy)
            }
        }

        // The title page of a film from the banner, its copies listed: Play
        // is on while they are asked for, the line under it only once here.
        function film() {
            mouseClick(findChild(shell, "moreInfo"))
            tryVerify(() => !!findChild(shell, "playLineChoose")?.enabled, 5000, "the copies listed")
        }

        // A row of the copies' drawer, which lives over the window rather
        // than in the page.
        function row(name) {
            const drawer = findChild(shell, "sourcesDrawer")
            return drawer.opened ? findChild(drawer.contentItem, name) : null
        }

        function openDrawer() {
            const line = findChild(shell, "playLineChoose")
            verify(waitForPolish(line.parent))
            mouseClick(line)
            // Opened once its slide is over, and its rows are laid out by then.
            tryVerify(() => !!row("copy-1"), 5000, "the drawer open")
            return row("copy-1")
        }

        function init() {
            const items = []
            for (let i = 0; i < 3; ++i) {
                const film = { id: "tt" + (2000 + i), kind: "movie", title: "Film " + i, year: 1920 + i }
                items.push(film)
                fakeCore.answer("GET", "/api/v1/items/" + film.id, 200, film)
                fakeCore.answer("GET", "/api/v1/progress/" + film.id, 200, {})
                fakeCore.answer("GET", "/api/v1/list/" + film.id, 200, { inList: false })
                fakeCore.answer("PUT", "/api/v1/list/" + film.id, 200, { inList: true })
                fakeCore.answer("GET", "/api/v1/ratings/" + film.id, 200, { ratings: [] })
                fakeCore.answer("PUT", "/api/v1/ratings/" + film.id, 200, { rating: 7 })
            }
            fakeCore.answer("GET", "/api/v1/catalog", 200, { items: items })
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy, other], providers: 1 })
            fakeCore.answer("PATCH", "/api/v1/choices/tt2001", 200, {})
            fakeCore.answer("PATCH", "/api/v1/choices/tt2002", 200, {})
            fakeCore.answer("POST", "/api/v1/downloads", 201, { id: "d1", itemId: "tt2001", state: "active" })
            asked = fakeCore.requests.length
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
            compare(posted().length, 0)
        }

        // A series, opened on its first episode with the keyboard on it.
        function series() {
            const show = fakeCore.read("items.json").find(item => item.kind === "series")
            fakeCore.answer("GET", "/api/v1/items/" + show.id, 200, show)
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, {})
            shell.open(show, false)
            const strip = findChild(shell, "episodes")
            tryVerify(() => strip.itemAtIndex(0)?.activeFocus, 5000, "the first episode has the keyboard")
            return show
        }

        function posted() {
            return requests().filter(r => r.startsWith("POST /api/v1/downloads"))
        }

        // The arrows walk the season with the selection; Enter plays what
        // they reached, and a run of steps asks for one list, not one per card.
        function test_theArrowsChooseAnEpisodeAndEnterPlaysIt() {
            series()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(findChild(shell, "titlePlay").text, "Play S1 E3")
            keyClick(Qt.Key_Return)
            watched.wait(5000)
            verify(posted().length === 1 && posted()[0].includes('"episode":3'), posted()[0])
            verify(!requests().some(r => r.includes("/api/v1/sources") && r.includes("episode=2")),
                   "no list for the episode passed over")
        }

        // Specials aside, the arrows go on into the next season.
        function test_theArrowsCrossIntoTheNextSeason() {
            series()
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Right)
            compare(findChild(shell, "titlePlay").text, "Play S2 E1")
            verify(findChild(shell, "season-2"), "two seasons, two tabs")
            keyClick(Qt.Key_Left)
            compare(findChild(shell, "titlePlay").text, "Play S1 E6")
        }

        function test_aSeasonTabShowsItsEpisodes() {
            series()
            mouseClick(findChild(shell, "season-2"))
            const strip = findChild(shell, "episodes")
            compare(strip.count, 1)
            compare(findChild(shell, "titlePlay").text, "Play S2 E1")
        }

        // A pick is the title's release, which the core keeps, so the next
        // episode goes on from it; nothing starts.
        function test_aCopyPickedInTheDrawerIsTheTitlesRelease() {
            film()
            mouseClick(openDrawer())
            tryVerify(() => requests().some(r => r.startsWith("PATCH /api/v1/choices/") && r.includes("720p WEB")))
            tryVerify(() => !findChild(shell, "sourcesDrawer").visible, 2000, "the drawer closed")
            compare(posted().length, 0)
        }

        function test_automaticForgetsTheRelease() {
            film()
            openDrawer()
            mouseClick(row("best"))
            tryVerify(() => requests().some(r => r.startsWith("PATCH /api/v1/choices/") && r.includes('{"source":null}')))
        }

        // "Ask every time": Play opens the copies, and the one picked plays.
        function test_askEveryTimeOpensTheCopiesAndPlaysThePick() {
            const prefs = fakeCore.read("preferences.json")
            prefs.askCopy = true
            fakeCore.answer("PATCH", "/api/v1/preferences", 200, prefs)
            Preferences.patch({ askCopy: true })
            tryVerify(() => Preferences.current.askCopy)
            film()
            mouseClick(findChild(shell, "titlePlay"))
            tryVerify(() => !!row("copy-1"), 5000, "the drawer open")
            compare(posted().length, 0)
            // What the core answers once the pick is recorded.
            const picked = Object.assign({ lastUsed: true }, other)
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy, picked], providers: 1 })
            mouseClick(row("copy-1"))
            watched.wait(5000)
            verify(posted()[0].includes("720p WEB"), posted()[0])
        }

        // Both change at once and go to the core behind the change.
        function test_myListAndTheScoreReachTheCore() {
            film()
            const list = findChild(shell, "listButton")
            tryVerify(() => list.enabled, 5000, "the core said")
            mouseClick(list)
            compare(list.glyph, "check")
            tryVerify(() => requests().some(r => r.startsWith("PUT /api/v1/list/")))

            const rating = findChild(shell, "ratingButton")
            mouseClick(rating)
            const scores = findChild(rating, "ratingScale")
            tryVerify(() => scores.opened)
            mouseClick(findChild(scores.contentItem, "score-7"))
            compare(rating.score, 7)
            tryVerify(() => requests().some(r => r.startsWith("PUT /api/v1/ratings/") && r.includes('"rating":7')))
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
