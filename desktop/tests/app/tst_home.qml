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

        // An arrow inside the row's list took the row's hover from it, so it
        // hid as soon as it was pointed at and came back, over and over.
        function test_anArrowUnderThePointerStays() {
            const strip = findChild(findChild(shell, "shelf-movie/top/"), "strip")
            const arrow = findChild(strip, "on")
            mouseMove(strip, strip.width - 20, strip.height / 2)
            tryCompare(arrow, "opacity", 1, 2000)
            // Two turns of the flicker, which took about 300 ms.
            wait(600)
            compare(arrow.opacity, 1)
        }

        // Flickable's wheel dropped the rest of a notch when the next came, so
        // spinning faster scrolled less. Quick notches now add up, each one
        // step: a gain that multiplied them made spins fly past.
        function test_notchesThatComeQuicklyAddUpAStepEach() {
            const list = findChild(shell, "shelves")
            const wheel = findChild(shell, "wheel")
            wheel.duration = 1000
            const start = list.contentY
            for (let i = 0; i < 3; ++i)
                mouseWheel(list, 700, 300, 0, -120)
            compare(wheel.goal, start + 3 * wheel.step)
            wheel.glide.complete()
            compare(list.contentY, start + 3 * wheel.step)
        }

        // What a mouse wheel on Wayland sends for one notch: a notch of angle and the compositor's
        // 10-15 px. Taking the pixels moved the page 10 px a notch.
        function test_aWaylandNotchMovesAStepNotTheCompositorsPixels() {
            const list = findChild(shell, "shelves")
            const wheel = findChild(shell, "wheel")
            wheel.duration = 0
            const start = list.contentY
            wheel.scroll({ angleDelta: Qt.point(0, -120), pixelDelta: Qt.point(0, -10),
                           phase: Qt.NoScrollPhase, modifiers: Qt.NoModifier })
            tryCompare(list, "contentY", start + wheel.step, 2000)
        }

        // A touchpad gesture has phases; the page follows the fingers.
        function test_aTouchpadGestureFollowsTheFingers() {
            const list = findChild(shell, "shelves")
            const wheel = findChild(shell, "wheel")
            const start = list.contentY
            wheel.scroll({ angleDelta: Qt.point(0, -24), pixelDelta: Qt.point(0, -17),
                           phase: Qt.ScrollUpdate, modifiers: Qt.NoModifier })
            compare(list.contentY, start + 17)
        }

        // Turning back mid-glide went on the old way until the unfinished target ran out.
        function test_turningBackGoesBackFromWhereThePageIs() {
            const list = findChild(shell, "shelves")
            const wheel = findChild(shell, "wheel")
            const notch = angle => wheel.scroll({ angleDelta: Qt.point(0, angle), pixelDelta: Qt.point(0, 0),
                                                  phase: Qt.NoScrollPhase, modifiers: Qt.NoModifier })
            // Down the page first, so there is room to turn back into.
            wheel.duration = 0
            notch(-120)
            notch(-120)
            tryVerify(() => list.contentY >= 2 * wheel.step, 2000, "room to turn back")
            wheel.duration = 1000
            notch(-120)
            notch(-120)
            wait(50)
            const here = list.contentY
            notch(120)
            verify(wheel.goal < here, "the page turns back at once")
        }

        function test_theArrowsWalkTheHeroAndTheShelvesAndEnterOpensATitle() {
            const focused = () => shell.Window.activeFocusItem
            const strip = name => findChild(findChild(shell, name), "strip")
            const holds = name => strip(name).activeFocus
            // A shelf whose first page has not come yet is passed over.
            tryVerify(() => strip("shelf-movie/top/").count > 0 && strip("shelf-series/top/").count > 0,
                      5000, "both shelves filled")
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
    }
}
