import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true; navigation: Navigation {} } }

    TestCase {
        name: "Library"
        when: windowShown

        property var shell
        property int asked
        readonly property var show: fakeCore.read("items.json").find(item => item.kind === "series")
        readonly property var film: ({ id: "tt0013442", kind: "movie", title: "Nosferatu", year: 1922 })

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        // Noon on this machine's calendar, [days] ago.
        function at(days) {
            const now = new Date()
            return new Date(now.getFullYear(), now.getMonth(), now.getDate() - days, 12).toISOString()
        }

        function line(episode, days, position) {
            const bare = Object.assign({}, show)
            delete bare.episodes
            return {
                item: bare,
                entry: { season: 1, episode: episode, position: position, duration: 1200,
                         watched: position === 0, updatedAt: at(days) },
                episode: show.episodes[episode - 1],
            }
        }

        function init() {
            fakeCore.answer("GET", "/api/v1/list", 200, { items: [
                { item: show, addedAt: at(1), rating: 7, seen: { watched: 2, released: 10, played: true } },
                { item: film, addedAt: at(2), seen: { watched: 0, released: 1 } },
            ] })
            fakeCore.answer("GET", "/api/v1/new-episodes", 200, { items: [
                { item: show, episode: Object.assign({}, show.episodes[2], { released: new Date().toISOString().slice(0, 10) + "T00:00:00Z" }), count: 1 },
            ] })
            const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10) + "T00:00:00Z"
            fakeCore.answer("GET", "/api/v1/coming-up", 200, { items: [
                { item: show, episode: { season: 2, number: 1, released: tomorrow } },
                { item: Object.assign({ released: tomorrow }, film) },
            ] })
            fakeCore.answer("GET", "/api/v1/history", 200, { entries: [line(2, 0, 480), line(1, 1, 0)], more: false })
            fakeCore.answer("PUT", "/api/v1/ratings/" + show.id, 200, { season: 1, episode: 1, rating: 9 })
            fakeCore.answer("GET", "/api/v1/items/" + show.id, 200, show)
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, {})
            fakeCore.answer("GET", "/api/v1/list/" + show.id, 200, { inList: true })
            fakeCore.answer("GET", "/api/v1/ratings/" + show.id, 200, { ratings: [] })
            shell = createTemporaryObject(shellComponent, window)
            tryVerify(() => findChild(shell, "play") !== null, 5000, "home")
            asked = fakeCore.requests.length
            mouseClick(findChild(shell, "tab-library"))
            tryCompare(shell, "page", "library")
        }

        function cleanup() {
            window.width = 1440
            window.height = 900
            LocalSettings.listSort = "added"
            LocalSettings.listKind = ""
        }

        // The grid's titles in order, once it has taken the last change in;
        // as many as it holds at once.
        function titles() {
            const grid = findChild(shell, "myList")
            grid.forceLayout()
            const out = []
            for (let i = 0; i < grid.count; ++i)
                out.push(grid.itemAtIndex(i).item.title)
            return out
        }

        // A row of the title menu once the title has answered, laid out.
        function menuRow(name) {
            const menu = findChild(shell, "titleMenu")
            tryVerify(() => menu.opened && menu.ready, 5000, "the menu open on its title")
            const found = findChild(menu.contentItem, name)
            tryVerify(() => found.visible && found.enabled && found.height > 0, 5000, name)
            waitForRendering(menu.contentItem)
            return found
        }

        // What the menu reads of [item] before it offers anything.
        function answerTitle(item, inList) {
            fakeCore.answer("GET", "/api/v1/items/" + item.id, 200, item)
            fakeCore.answer("GET", "/api/v1/progress/" + item.id, 200, {})
            fakeCore.answer("GET", "/api/v1/list/" + item.id, 200, { inList: inList })
            fakeCore.answer("GET", "/api/v1/ratings/" + item.id, 200, { ratings: [] })
            fakeCore.answer("PUT", "/api/v1/progress/" + item.id, 200, {})
        }

        function history() {
            mouseClick(findChild(shell, "place-history"))
            tryVerify(() => !!findChild(shell, "line-" + show.id + "/1/1"), 5000, "the history")
        }

        function test_myListSaysHowFarAndComesBackFromATitleReadAgain() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            // The shelves came with the list and grew the grid's header: the
            // page stays at its top rather than where the grid was.
            const grid = findChild(shell, "myList")
            tryVerify(() => grid.contentY === grid.originY, 2000, "at the top: " + grid.contentY + " " + grid.originY)
            const listed = findChild(shell, "listed-" + show.id)
            compare(listed.line, "2 of 10 seen")
            compare(listed.score, 7)
            // Nothing watched and no score: the kind is all there is to say.
            compare(findChild(shell, "listed-" + film.id).line, "Film")
            compare(findChild(shell, "fresh-" + show.id).line, "S1 E3 · Today")
            compare(findChild(shell, "comingUp-" + show.id).line, "S2 E1 · Tomorrow")
            // A film has no episode: its own date.
            compare(findChild(shell, "comingUp-" + film.id).line, "Film · Tomorrow")

            // Under the shelves it is below the window: pressed there, the
            // press lands nowhere.
            grid.positionViewAtIndex(0, GridView.Contain)
            verify(listed.mapToItem(window, 0, 0).y + listed.height <= window.height, "the title in the window")
            mouseClick(listed)
            tryCompare(shell, "page", "title")
            fakeCore.answer("GET", "/api/v1/list", 200, { items: [] })
            keyClick(Qt.Key_Escape)
            tryCompare(shell, "page", "library")
            tryVerify(() => findChild(shell, "listEmpty")?.visible === true, 5000, "the list read again")
        }

        // Left for home, the library goes; come back to, it is made again
        // from the list kept with the navigation, which shows at once and is
        // read again behind it. Everything else starts over, as on a library
        // opened anew.
        function test_theLibraryComesBackWithItsListShownAtOnce() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            history()
            mouseClick(findChild(shell, "tab-home"))
            tryCompare(shell, "page", "home")
            tryVerify(() => !findChild(shell, "library"), 2000, "the library gone")
            fakeCore.answer("GET", "/api/v1/list", 200, { items: [] })
            mouseClick(findChild(shell, "tab-library"))
            compare(shell.page, "library")
            compare(findChild(shell, "library").section, "list")
            verify(findChild(shell, "listed-" + film.id)?.visible, "the list at once")
            tryVerify(() => findChild(shell, "listEmpty")?.visible === true, 5000, "the list read again")
        }

        function test_theOrderChosenIsKeptOnThisMachine() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            mouseClick(findChild(shell, "sort"))
            const orders = findChild(shell, "orders")
            tryVerify(() => orders.opened)
            mouseClick(findChild(orders.contentItem, "order-title"))
            compare(LocalSettings.listSort, "title")
            compare(titles(), ["Breaking Bad", "Nosferatu"])
        }

        // A stage narrows the grid for now; a kind is kept on this machine,
        // as the order is.
        function test_aStageAndAKindNarrowTheList() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            mouseClick(findChild(shell, "stage-toWatch"))
            compare(titles(), ["Nosferatu"])
            mouseClick(findChild(shell, "stage-watched"))
            compare(titles(), [])
            verify(findChild(shell, "stageEmpty").visible, "says the stage is empty")
            mouseClick(findChild(shell, "stage-all"))

            mouseClick(findChild(shell, "sort"))
            const orders = findChild(shell, "orders")
            tryVerify(() => orders.opened)
            mouseClick(findChild(orders.contentItem, "kind-series"))
            compare(LocalSettings.listKind, "series")
            compare(titles(), ["Breaking Bad"])
        }

        // The grid's own arrows walk it a title and a row at a time, and up
        // from its first row is the shelf over it.
        function test_theArrowsWalkTheGrid() {
            const many = []
            for (let i = 0; i < 9; ++i)
                many.push({ item: { id: "tt90" + i, kind: "movie", title: "Film " + i, year: 2000 + i },
                            addedAt: at(i), seen: { watched: 0, released: 1 } })
            fakeCore.answer("GET", "/api/v1/list", 200, { items: many })
            mouseClick(findChild(shell, "tab-home"))
            tryCompare(shell, "page", "home")
            mouseClick(findChild(shell, "tab-library"))
            const grid = findChild(shell, "myList")
            tryCompare(grid, "count", 9, 5000, "the nine titles")
            const columns = findChild(shell, "library").columns
            verify(columns > 1 && columns < 9, columns + " columns")

            const coming = findChild(shell, "comingUp")
            tryVerify(() => coming.visible, 5000, "Coming up")
            coming.focusCard(0)
            keyClick(Qt.Key_Down)
            const on = () => grid.currentItem?.button.activeFocus ? grid.currentIndex : -1
            tryCompare(grid, "currentIndex", 0)
            verify(on() === 0, "the first title has the keyboard")
            keyClick(Qt.Key_Right)
            tryVerify(() => on() === 1, 2000, "a title on")
            keyClick(Qt.Key_Down)
            tryVerify(() => on() === 1 + columns, 2000, "a row down")
            keyClick(Qt.Key_Up)
            tryVerify(() => on() === 1, 2000, "a row up")
            keyClick(Qt.Key_Up)
            tryVerify(() => findChild(shell, "comingUp-" + show.id)?.button.activeFocus ?? false, 2000, "the shelf over the grid")
        }

        // My list was a new model on every stage and every reading again, and
        // a view handed one goes back to its start: the page jumped to its top,
        // the chips just pressed under the shelves out of sight.
        function test_myListKeepsItsPlace() {
            const many = []
            for (let i = 0; i < 60; ++i)
                many.push({ item: { id: "tt90" + i, kind: "movie", title: "Film " + i, year: 2000 },
                            addedAt: at(i), seen: { watched: 0, released: 1, played: i % 10 === 9 } })
            fakeCore.answer("GET", "/api/v1/list", 200, { items: many })
            mouseClick(findChild(shell, "tab-home"))
            tryCompare(shell, "page", "home")
            mouseClick(findChild(shell, "tab-library"))
            const grid = findChild(shell, "myList")
            tryCompare(grid, "count", 60, 5000, "the sixty titles")
            tryVerify(() => findChild(shell, "comingUp").visible, 5000, "Coming up")
            waitForPolish(grid)

            const stage = findChild(shell, "stage-toWatch")
            grid.contentY = stage.mapToItem(grid.contentItem, 0, 0).y - 300
            const kept = grid.contentY
            verify(kept > grid.originY + 300, "under the shelves: " + kept)
            mouseClick(stage)
            grid.forceLayout()
            compare(grid.count, 54)
            compare(grid.contentY, kept, "a stage")

            // Marked watched from its menu, the first leaves To watch.
            const film = many[0].item
            answerTitle(film, true)
            const tile = findChild(shell, "listed-" + film.id)
            mouseClick(tile, tile.width / 2, 40, Qt.RightButton)
            const watched = menuRow("menuWatched")
            many[0].seen = { watched: 1, released: 1, played: true }
            fakeCore.answer("GET", "/api/v1/list", 200, { items: many })
            mouseClick(watched)
            tryCompare(grid, "count", 53, 5000, "the list read again")
            grid.forceLayout()
            compare(grid.contentY, kept, "a reading again")
        }

        // The history was made anew on every title changed from a menu, and
        // went back to its start as My list did.
        function test_theHistoryKeepsItsPlaceReadAgain() {
            const lines = []
            for (let e = 1; e <= 30; ++e)
                lines.push(line(e, 0, 480))
            fakeCore.answer("GET", "/api/v1/history", 200, { entries: lines, more: false })
            history()
            const view = findChild(shell, "history")
            view.contentY = view.originY + 1000
            const kept = view.contentY
            waitForPolish(view)

            const shown = view.itemAt(100, view.contentY + 300)
            answerTitle(show, true)
            mouseClick(shown, 200, shown.height / 2, Qt.RightButton)
            const watched = menuRow("menuWatched")
            const episode = shown.entry.episode
            lines[episode - 1] = line(episode, 0, 0)
            fakeCore.answer("GET", "/api/v1/history", 200, { entries: lines, more: false })
            mouseClick(watched)
            tryVerify(() => findChild(findChild(shell, "line-" + show.id + "/1/" + episode), "state")?.text === "Watched",
                      5000, "the history read again")
            compare(view.contentY, kept)
            verify(requests().includes("GET /api/v1/history?limit=50"), "read as far as before")
        }

        function test_theHistoryIsByDayTheLatestFirst() {
            history()
            const latest = findChild(shell, "line-" + show.id + "/1/2")
            const before = findChild(shell, "line-" + show.id + "/1/1")
            verify(latest.y < before.y)
            compare(findChild(latest, "state").text, "12 min left")
            compare(findChild(before, "state").text, "Watched")
            const days = [...findChild(shell, "history").contentItem.children]
                .filter(child => child.section !== undefined)
                .sort((a, b) => a.y - b.y)
                .map(child => child.text)
            compare(days, ["Today", "Yesterday"])
        }

        function test_anEpisodeIsScoredFromItsLine() {
            history()
            const line = findChild(shell, "line-" + show.id + "/1/1")
            const score = findChild(line, "score")
            mouseClick(score)
            const scale = findChild(score, "ratingScale")
            tryVerify(() => scale.opened)
            mouseClick(findChild(scale.contentItem, "score-9"))
            tryVerify(() => requests().includes('PUT /api/v1/ratings/' + show.id + ' {"episode":1,"rating":9,"season":1}'))
            compare(score.score, 9)
        }

        // The core is told once the undo runs out (library_test.cpp).
        function test_aLineTakenOutComesBackWithUndo() {
            history()
            const id = "line-" + show.id + "/1/2"
            mouseClick(findChild(findChild(shell, id), "remove"))
            tryVerify(() => !findChild(shell, id))
            const undo = findChild(shell, "toastAction")
            verify(undo.visible)
            mouseClick(undo)
            tryVerify(() => !!findChild(shell, id))
            verify(!undo.visible)
            compare(requests().filter(r => r.startsWith("DELETE")), [])
        }

        function test_aLineOpensItsTitleOnItsEpisode() {
            history()
            mouseClick(findChild(shell, "line-" + show.id + "/1/2"))
            tryCompare(shell, "page", "title")
            const title = findChild(shell, "title")
            tryVerify(() => title.current?.number === 2, 5000, "the second episode")
        }
    }
}
