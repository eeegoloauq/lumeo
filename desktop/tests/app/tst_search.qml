import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    TestCase {
        name: "Search"
        when: windowShown

        property var shell
        // Where this test's requests start in the fake core's log.
        property int asked

        readonly property var living: ({ id: "tt0063350", kind: "movie", title: "Night of the Living Dead", year: 1968,
                                         background: "http://127.0.0.1:1/living.jpg" })
        readonly property var hunter: ({ id: "tt0048424", kind: "movie", title: "The Night of the Hunter", year: 1955 })
        readonly property var gallery: ({ id: "tt0066685", kind: "series", title: "Night Gallery", year: 1969, yearEnd: 1973 })

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function field() {
            return findChild(shell, "searchField")
        }

        function type(word) {
            for (const letter of word)
                keyClick(letter)
        }

        // The page's best match, once the word has been answered.
        function best() {
            return findChild(findChild(shell, "search"), "best")
        }

        function focused() {
            return shell.Window.activeFocusItem
        }

        function init() {
            fakeCore.answerBy("GET", "/api/v1/search", "kind", {
                movie: { items: [living, hunter] },
                series: { items: [gallery] },
            })
            fakeCore.answer("GET", "/api/v1/searches", 200, { searches: [] })
            fakeCore.answer("POST", "/api/v1/searches", 204)
            shell = createTemporaryObject(shellComponent, window)
            findChild(shell, "finder").wait = 0
            tryVerify(() => findChild(shell, "play") !== null, 5000, "home")
            asked = fakeCore.requests.length
            keySequence("Ctrl+F")
            tryCompare(shell, "page", "search")
        }

        // The Flutter client waited for Enter and then replaced the page; the
        // titles now come as the word is typed, and a title opened and left
        // comes back to the same search.
        function test_titlesComeAsTheWordIsTypedAndBackReturnsToThem() {
            type("night")
            tryVerify(() => best()?.visible === true, 5000, "the best match")
            compare(best().item.id, living.id)
            const series = findChild(shell, "result-" + gallery.id)
            verify(series !== null, "the other kind among them")
            waitForRendering(shell)

            mouseClick(series)
            compare(shell.page, "title")
            compare(findChild(shell, "title").item.id, gallery.id)
            tryVerify(() => requests().includes('POST /api/v1/searches {"query":"night"}'),
                      2000, "the word remembered")

            keyClick(Qt.Key_Escape)
            compare(shell.page, "search")
            compare(field().text, "night")
            verify(field().activeFocus, "the keyboard back in the field")
            verify(best().visible)
        }

        function test_enterOpensTheBestMatch() {
            type("night")
            keyClick(Qt.Key_Return)
            tryCompare(shell, "page", "title")
            compare(findChild(shell, "title").item.id, living.id)
        }

        // A text field keeps the arrows for its caret; Down leaves it for the
        // titles, and Up from their first row comes back.
        function test_theArrowsWalkFromTheFieldIntoTheTitlesAndBack() {
            type("night")
            tryVerify(() => best()?.visible === true, 5000, "the best match")
            keyClick(Qt.Key_Down)
            verify(best().activeFocus, "the best match first")
            keyClick(Qt.Key_Right)
            compare(focused().item.id, gallery.id)
            keyClick(Qt.Key_Up)
            verify(field().activeFocus, "back in the field")
        }

        function test_theKindsFilterTheTitles() {
            type("night")
            tryVerify(() => best()?.visible === true, 5000, "the best match")
            mouseClick(findChild(shell, "kind-series"))
            tryCompare(best(), "item", gallery)
            compare(findChild(shell, "result-" + living.id), null)
        }

        function test_aSearchFromBeforeIsAskedAgainFromTheEmptyField() {
            fakeCore.answer("GET", "/api/v1/searches", 200, { searches: ["night", "metropolis"] })
            keyClick(Qt.Key_Escape)
            keySequence("Ctrl+F")
            tryVerify(() => findChild(shell, "recent-night")?.visible === true, 2000, "the searches from before")
            waitForRendering(shell)
            mouseClick(findChild(shell, "recent-night"))
            compare(field().text, "night")
            tryVerify(() => best()?.visible === true, 5000, "its titles")
        }

        // A core that does not answer is not "nothing found", and is asked
        // again from the page.
        function test_nothingFoundAndNoAnswerAreToldApart() {
            fakeCore.answer("GET", "/api/v1/search", 200, { items: [] })
            type("zzz")
            tryVerify(() => findChild(shell, "nothing").visible, 5000, "nothing found")

            fakeCore.answer("GET", "/api/v1/search", 502, { error: "down" })
            keyClick("y")
            const trouble = findChild(shell, "unanswered")
            tryVerify(() => trouble.visible, 5000, "the catalogue not answering")
            verify(!findChild(shell, "nothing").visible)

            fakeCore.answerBy("GET", "/api/v1/search", "kind", {
                movie: { items: [living] },
                series: { items: [] },
            })
            waitForRendering(shell)
            mouseClick(findChild(trouble, "action"))
            tryVerify(() => best()?.visible === true, 5000, "asked again")
        }
    }
}
