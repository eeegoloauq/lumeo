import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    TestCase {
        name: "Home"
        when: windowShown

        property var shell

        // A shelf long enough to scroll sideways.
        function films(count) {
            const items = []
            for (let i = 0; i < count; ++i)
                items.push({ id: "tt" + (1000 + i), kind: "movie", title: "Film " + i, year: 1950 + i })
            return { items: items }
        }

        function init() {
            fakeCore.answer("GET", "/api/v1/catalog", 200, films(30))
            shell = createTemporaryObject(shellComponent, window)
            tryVerify(() => findChild(shell, "play") !== null, 5000, "the hero")
            // The shelves past the window are made over the next frames, and
            // until they are the list's height is a guess that a wheel can
            // land in the middle of.
            const list = findChild(shell, "shelves")
            tryVerify(() => list.itemAtIndex(list.count - 1) !== null, 5000, "every shelf")
            // Laid out, so the pointer lands where the items are drawn.
            waitForRendering(shell)
        }

        // A row that took the wheel stopped the page wherever the pointer
        // rested; sideways is shift with the wheel (decisions/interface.md).
        function test_theWheelOverAShelfScrollsThePageAndShiftScrollsTheShelf() {
            const list = findChild(shell, "shelves")
            const strip = findChild(findChild(shell, "shelf-movie/top/"), "strip")
            const start = strip.contentX
            mouseWheel(strip, 400, 100, 0, -120)
            tryVerify(() => list.contentY > 0, 2000, "the page moved")
            compare(strip.contentX, start)

            mouseWheel(strip, 400, 100, 0, -120, Qt.NoButton, Qt.ShiftModifier)
            tryVerify(() => strip.contentX > start, 2000, "the shelf moved")
        }

        function test_theArrowsWalkTheHeroAndTheShelvesAndEnterOpensATitle() {
            const focused = () => shell.Window.activeFocusItem
            const holds = name => findChild(findChild(shell, name), "strip").activeFocus
            keyClick(Qt.Key_Down)
            verify(findChild(shell, "play").activeFocus, "Play first")
            keyClick(Qt.Key_Down)
            verify(holds("shelf-movie/top/"), "then the shelf over the hero")
            const first = focused().item.id
            keyClick(Qt.Key_Right)
            const second = focused().item.id
            verify(second !== first, "along the shelf")
            keyClick(Qt.Key_Down)
            verify(holds("shelf-series/top/"), "down to the next shelf")
            keyClick(Qt.Key_Up)
            verify(holds("shelf-movie/top/"), "and back up")

            const card = focused().item.id
            keyClick(Qt.Key_Return)
            compare(shell.page, "title")
            compare(findChild(shell, "title").item.id, card)
            keyClick(Qt.Key_Escape)
            compare(shell.page, "home")
        }

        // Play in the banner opened the title without starting it.
        function test_playInTheBannerOpensTheTitleToStartIt() {
            mouseClick(findChild(shell, "play"))
            compare(shell.page, "title")
            verify(findChild(shell, "title").play)
            keyClick(Qt.Key_Escape)
            mouseClick(findChild(shell, "moreInfo"))
            verify(!findChild(shell, "title").play)
        }
    }
}
