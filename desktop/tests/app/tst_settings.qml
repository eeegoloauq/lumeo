import QtQuick
import QtTest
import QtQuick.Controls
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    TestCase {
        name: "Settings"
        when: windowShown

        property var shell
        property var page
        // Where this test's requests start in the fake core's log.
        property int asked

        function patches() {
            return fakeCore.requests.slice(asked).filter(r => r.startsWith("PATCH /api/v1/preferences"))
        }

        function init() {
            fakeCore.answer("PATCH", "/api/v1/preferences", 200, fakeCore.read("preferences.json"))
            shell = createTemporaryObject(shellComponent, window)
            mouseClick(findChild(shell, "tab-settings"))
            page = findChild(shell, "settings")
            tryVerify(() => findChild(page, "seekStep")?.visible === true, 5000, "the preferences")
            waitForRendering(page)
            asked = fakeCore.requests.length
        }

        function test_aPressInTheListScrollsToItsSectionAndLightsIt() {
            mouseClick(findChild(page, "nav-playback"))
            tryCompare(page, "lit", "playback")
        }

        // A value outside the presets is asked for, and only a number in
        // range can be set.
        function test_customAsksForANumberAndSendsIt() {
            const seek = findChild(page, "seekStep")
            mouseClick(findChild(seek, "segment--1"))
            const field = findChild(window.Overlay.overlay, "number")
            tryVerify(() => field?.activeFocus === true, 2000, "the question")
            keyClick(Qt.Key_A, Qt.ControlModifier)
            keyClick("1")
            keyClick("5")
            keyClick(Qt.Key_Return)
            tryVerify(() => patches().length === 1, 2000)
            verify(patches()[0].includes('"seekStep":15'), patches()[0])
        }

        // Each press shows at once; only the last of a burst is sent.
        function test_aSteppedNumberSendsTheLastOfABurst() {
            const stepper = findChild(page, "nextNotice")
            const more = findChild(stepper, "more")
            for (let i = 0; i < 3; ++i)
                mouseClick(more)
            compare(stepper.shown, 15)
            tryVerify(() => patches().length === 1, 2000)
            verify(patches()[0].includes('"nextNotice":15'), patches()[0])
        }

        // The core's refusal is said beside the preference it refused, not
        // at the top of the page.
        function test_aRefusalIsSaidInTheSectionOfItsPreference() {
            fakeCore.answer("PATCH", "/api/v1/preferences", 400, { error: "seekStep out of range" })
            mouseClick(findChild(findChild(page, "seekStep"), "segment-10"))
            tryCompare(page, "changedIn", "playback")
            tryVerify(() => page.errorIn("playback") !== "", 2000)
            compare(page.errorIn("appearance"), "")
        }
    
        // A language is found by typing its name; Enter takes the first
        // that matches, at the end of the list.
        function test_aLanguageIsAddedByItsNameAndRemovedByItsChip() {
            mouseClick(findChild(page, "nav-audioSubtitles"))
            tryCompare(page, "reading", "audioSubtitles", 2000, "scrolled there")
            const list = findChild(page, "subtitleLanguages")
            mouseClick(findChild(list, "addLanguage"))
            const filter = findChild(list, "filter")
            tryVerify(() => filter.activeFocus, 2000, "the picker")
            for (const letter of "germ")
                keyClick(letter)
            keyClick(Qt.Key_Return)
            tryVerify(() => patches().length === 1, 2000)
            verify(patches()[0].includes('"subtitleLanguages":["en","de"]'), patches()[0])

            mouseClick(findChild(findChild(list, "language-en"), "remove"))
            tryVerify(() => patches().length === 2, 2000)
            verify(patches()[1].includes('"subtitleLanguages":[]'), patches()[1])
        }
    }
}
