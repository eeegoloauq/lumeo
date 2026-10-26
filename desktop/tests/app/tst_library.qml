import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

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
                { item: show, addedAt: at(1), rating: 7, seen: { watched: 2, released: 10 } },
                { item: film, addedAt: at(2), seen: { watched: 0, released: 1 } },
            ] })
            fakeCore.answer("GET", "/api/v1/new-episodes", 200, { items: [
                { item: show, episode: Object.assign({}, show.episodes[2], { released: new Date().toISOString().slice(0, 10) + "T00:00:00Z" }), count: 1 },
            ] })
            const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10) + "T00:00:00Z"
            fakeCore.answer("GET", "/api/v1/coming-up", 200, { items: [
                { item: show, episode: { season: 2, number: 1, released: tomorrow } },
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
            LocalSettings.listSort = "added"
        }

        function history() {
            mouseClick(findChild(shell, "place-history"))
            tryVerify(() => !!findChild(shell, "line-" + show.id + "/1/1"), 5000, "the history")
        }

        function test_myListSaysHowFarAndComesBackFromATitleReadAgain() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            const listed = findChild(shell, "listed-" + show.id)
            compare(listed.line, "2 of 10 seen")
            compare(listed.score, 7)
            // Nothing watched and no score: the kind is all there is to say.
            compare(findChild(shell, "listed-" + film.id).line, "Film")
            compare(findChild(shell, "fresh-" + show.id).line, "S1 E3 · Today")
            compare(findChild(shell, "comingUp-" + show.id).line, "S2 E1 · Tomorrow")

            mouseClick(listed)
            tryCompare(shell, "page", "title")
            fakeCore.answer("GET", "/api/v1/list", 200, { items: [] })
            keyClick(Qt.Key_Escape)
            tryCompare(shell, "page", "library")
            tryVerify(() => findChild(shell, "listEmpty")?.visible === true, 5000, "the list read again")
        }

        function test_theOrderChosenIsKeptOnThisMachine() {
            tryVerify(() => !!findChild(shell, "listed-" + film.id), 5000, "the list")
            mouseClick(findChild(shell, "sort"))
            const orders = findChild(shell, "orders")
            tryVerify(() => orders.opened)
            mouseClick(findChild(orders.contentItem, "order-title"))
            compare(LocalSettings.listSort, "title")
            compare(findChild(shell, "library").titles.map(t => t.item.title), ["Breaking Bad", "Nosferatu"])
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
