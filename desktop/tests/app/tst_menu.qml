import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    TestCase {
        name: "Menu"
        when: windowShown

        property var shell
        // Where this test's requests start in the fake core's log.
        property int asked

        readonly property var show: fakeCore.read("items.json").find(item => item.kind === "series")
        readonly property var watching: ({
            entries: [{ season: 1, episode: 3, position: 600, duration: 2900, watched: false,
                        updatedAt: "2026-09-01T00:00:00Z" }],
            next: { season: 1, episode: 3, position: 600, duration: 2900, watched: false,
                    updatedAt: "2026-09-01T00:00:00Z" },
        })

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function menu() {
            return findChild(shell, "titleMenu")
        }

        // A row of the open menu once the title has answered, laid out, so a
        // click lands on it rather than on the row it pushed down.
        function row(name) {
            tryVerify(() => menu().opened && menu().ready, 5000, "the menu open on its title")
            const found = findChild(menu().contentItem, name)
            tryVerify(() => found.visible && found.enabled && found.height > 0, 5000, name)
            waitForRendering(menu().contentItem)
            return found
        }

        function init() {
            fakeCore.answer("GET", "/api/v1/items/" + show.id, 200, show)
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, watching)
            fakeCore.answer("GET", "/api/v1/list/" + show.id, 200, { inList: true })
            fakeCore.answer("GET", "/api/v1/ratings/" + show.id, 200, { ratings: [] })
            fakeCore.answer("DELETE", "/api/v1/continue/" + show.id, 204)
            fakeCore.answer("DELETE", "/api/v1/progress/" + show.id, 204)
            fakeCore.answer("POST", "/api/v1/progress/" + show.id + "/watched-through", 200, watching)
            fakeCore.answer("GET", "/api/v1/continue", 200, [{
                item: { id: show.id, kind: "series", title: show.title },
                next: watching.next,
                updatedAt: "2026-09-01T00:00:00Z",
            }])
            asked = fakeCore.requests.length
            shell = createTemporaryObject(shellComponent, window)
            tryVerify(() => findChild(shell, "play") !== null, 5000, "the hero")
            waitForRendering(shell)
        }

        function cleanup() {
            menu()?.close()
            Viewing.undoTime = 5000
            fakeCore.answer("GET", "/api/v1/continue", 200, [])
        }

        // The card of the series in Continue watching.
        function continuing() {
            const strip = findChild(findChild(shell, "shelf-/continue/"), "strip")
            tryVerify(() => strip.itemAtIndex(0) !== null, 5000, "Continue watching")
            waitForRendering(shell)
            return strip.itemAtIndex(0)
        }

        // The keyboard has the same menu as the right button: the Menu key
        // and Shift+F10 on the card it is on.
        function test_theRightButtonAndTheKeyboardOpenTheMenu() {
            const card = continuing()
            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            tryVerify(() => menu().opened, 2000, "opened by the right button")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !menu().visible, 2000, "closed")

            card.forceActiveFocus(Qt.TabFocusReason)
            keyClick(Qt.Key_Menu)
            tryVerify(() => menu().opened, 2000, "opened by the Menu key")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !menu().visible, 2000, "closed")

            card.forceActiveFocus(Qt.TabFocusReason)
            keyClick(Qt.Key_F10, Qt.ShiftModifier)
            tryVerify(() => menu().opened && menu().ready, 2000, "opened by Shift+F10")
            // The arrows pass over the rows that do not apply here.
            for (let i = 0; i < 12; ++i) {
                keyClick(Qt.Key_Down)
                const lit = menu().itemAt(menu().currentIndex)
                verify(lit && lit.visible && lit.height > 0, "row " + menu().currentIndex + " is one shown")
            }
        }

        // Taken out of the row, the series is read again and keeps where it
        // was: the core is asked to hide it, not to forget it.
        function test_aTitleIsTakenOutOfContinueWatching() {
            const card = continuing()
            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            const hide = row("menuHide")
            fakeCore.answer("GET", "/api/v1/continue", 200, [])
            mouseClick(hide)
            tryVerify(() => requests().includes("DELETE /api/v1/continue/" + show.id), 2000, "asked to hide it")
            tryVerify(() => findChild(shell, "shelf-/continue/") === null, 5000, "the row read again")
            verify(!requests().some(r => r.startsWith("DELETE /api/v1/progress/")), "nothing forgotten")
        }

        // Marked unwatched, a series is forgotten only once its undo is over.
        function test_aSeriesMarkedUnwatchedWaitsForItsUndo() {
            Viewing.undoTime = 60000
            let card = continuing()
            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            mouseClick(row("menuForget"))
            tryVerify(() => !menu().visible, 2000, "the menu gone")
            const undo = findChild(shell, "toastAction")
            tryVerify(() => undo.visible, 2000, "the undo")
            // Its row is placed on the next polish; until then the button is
            // outside the toast.
            verify(waitForPolish(undo.parent))
            mouseClick(undo)
            tryVerify(() => Viewing.forgetting === "", 2000, "undone")
            verify(!requests().some(r => r.startsWith("DELETE /api/v1/progress/")), "nothing sent before the undo is over")

            Viewing.undoTime = 10
            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            mouseClick(row("menuForget"))
            tryVerify(() => requests().includes("DELETE /api/v1/progress/" + show.id), 2000, "forgotten")
        }

        // On an episode's card, the series is marked up to and including it.
        function test_anEpisodeCardMarksTheSeriesWatchedUpToIt() {
            shell.open(show, false, null)
            const strip = findChild(shell, "episodes")
            tryVerify(() => strip?.itemAtIndex(1) ?? false, 5000, "the episodes")
            waitForRendering(shell)
            const card = strip.itemAtIndex(1)
            // Escape closes the menu and leaves the page where it is.
            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            tryVerify(() => menu().opened, 2000, "the menu open")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !menu().visible, 2000, "closed")
            compare(shell.page, "title")

            mouseClick(card, card.width / 2, 40, Qt.RightButton)
            const upTo = row("menuWatchedUpTo")
            const progressRead = requests().filter(r => r === "GET /api/v1/progress/" + show.id).length
            mouseClick(upTo)
            tryVerify(() => requests().includes('POST /api/v1/progress/' + show.id + '/watched-through {"episode":2,"season":1}'),
                      2000, "marked up to S1 E2")
            tryVerify(() => requests().filter(r => r === "GET /api/v1/progress/" + show.id).length > progressRead,
                      2000, "the page read again")
        }
    }
}
