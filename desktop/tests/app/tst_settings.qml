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

        function deletes() {
            return fakeCore.requests.slice(asked).filter(r => r.startsWith("DELETE "))
        }

        function init() {
            fakeCore.answer("PATCH", "/api/v1/preferences", 200, fakeCore.read("preferences.json"))
            fakeCore.answer("GET", "/api/v1/storage", 200, {
                used: 6442450944, cache: 1048576, disk: { total: 500e9, free: 200e9 },
                titles: fakeCore.read("storage-titles.json"),
            })
            fakeCore.answer("GET", "/api/v1/about", 200, fakeCore.read("about.json"))
            fakeCore.answer("DELETE", "/api/v1/storage", 204)
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
    
        function onDisk() {
            mouseClick(findChild(page, "nav-downloads"))
            tryCompare(page, "lit", "downloads")
            const list = findChild(page, "onDisk")
            tryVerify(() => findChild(list, "title-tt2543164") !== null, 2000, "what is on disk")
            tryVerify(() => !findChild(page, "going")?.running, 2000)
            // Down to the list, as a viewer would scroll.
            const view = findChild(page, "view")
            view.contentY = Math.min(list.mapToItem(view.contentItem, 0, 0).y - 200,
                                     view.contentHeight - view.height)
            waitForRendering(page)
            return list
        }

        function test_aTitleOnDiskIsFreedAndTheListReadAgain() {
            const list = onDisk()
            const reads = fakeCore.requests.filter(r => r.startsWith("GET /api/v1/storage")).length
            mouseClick(findChild(findChild(list, "title-tt2543164"), "delete"))
            tryVerify(() => deletes().length === 1, 2000)
            compare(deletes()[0].split(" ")[1], "/api/v1/storage?item=tt2543164")
            tryVerify(() => fakeCore.requests.filter(r => r.startsWith("GET /api/v1/storage")).length > reads,
                      2000, "read again")
        }

        // Everything goes only once it has been asked about.
        function test_deleteAllAsksFirst() {
            onDisk()
            mouseClick(findChild(page, "deleteAll"))
            const confirm = findChild(findChild(page, "confirmAll").footer, "confirm")
            tryVerify(() => confirm?.visible === true, 2000, "the question")
            compare(deletes().length, 0)
            mouseClick(confirm)
            tryVerify(() => deletes().length === 1, 2000)
            compare(deletes()[0].split(" ")[1], "/api/v1/storage")
        }

        // The limit is asked in gigabytes and kept in bytes.
        function test_aCustomDiskLimitIsSentInBytes() {
            mouseClick(findChild(page, "nav-downloads"))
            tryVerify(() => !findChild(page, "going").running, 2000)
            mouseClick(findChild(findChild(page, "diskLimit"), "segment--1"))
            const field = findChild(window.Overlay.overlay, "number")
            tryVerify(() => field?.activeFocus === true, 2000, "the question")
            keyClick(Qt.Key_A, Qt.ControlModifier)
            for (const digit of "250")
                keyClick(digit)
            keyClick(Qt.Key_Return)
            tryVerify(() => patches().length === 1, 2000)
            verify(patches()[0].includes('"diskLimit":268435456000'), patches()[0])
        }
    
        // Reset asks first, and puts back this machine's choices as well as
        // the core's.
        function test_resetAsksAndPutsBackBothKinds() {
            LocalSettings.timelinePreviews = false
            fakeCore.answer("DELETE", "/api/v1/preferences", 200, fakeCore.read("preferences.json"))
            // Pressed before the sections above have all answered: the page
            // follows them as they grow.
            mouseClick(findChild(page, "nav-about"))
            const reset = findChild(page, "reset")
            const view = findChild(page, "view")
            tryVerify(() => reset.mapToItem(view, 0, 0).y + reset.height <= view.height, 3000, "in view")
            waitForRendering(page)
            mouseClick(reset)
            const confirm = findChild(findChild(page, "confirmReset").footer, "confirm")
            tryVerify(() => confirm?.visible === true, 2000, "the question")
            verify(LocalSettings.timelinePreviews === false, "nothing before the answer")
            mouseClick(confirm)
            tryVerify(() => deletes().some(r => r.startsWith("DELETE /api/v1/preferences")), 2000)
            verify(LocalSettings.timelinePreviews)
        }
    }
}
