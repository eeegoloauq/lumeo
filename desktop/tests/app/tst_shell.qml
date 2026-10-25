import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Shell {
        id: shell
        anchors.fill: parent
        focus: true
    }

    TestCase {
        name: "Shell"
        when: windowShown

        function cleanup() {
            shell.place("home")
        }

        function lit() {
            return ["home", "library", "settings"].filter(
                name => findChild(shell, "tab-" + name).lit)
        }

        // A title page could be left only by Escape, Alt+Left or the mouse's
        // side button, and lit the tab it was opened from as if it were there.
        function test_aPageWithAWayBackHasAnArrowForItAndLightsNoTab() {
            const back = findChild(shell, "back")
            verify(!back.visible, "Home is where back ends")
            compare(lit(), ["home"])

            mouseClick(findChild(shell, "search"))
            tryVerify(() => back.visible)
            compare(lit(), [])

            mouseClick(back)
            tryVerify(() => !back.visible)
            compare(lit(), ["home"])
        }

        // Keys climb from whatever holds the keyboard, so a window whose focus
        // landed nowhere answered no shortcut: it cost F11 on a window nobody
        // had clicked, and later back, fullscreen and search together.
        function test_ctrlFAndEscapeAnswerFromAWindowNobodyClicked() {
            window.forceActiveFocus()
            keySequence("Ctrl+F")
            tryCompare(shell, "page", "search")
            verify(window.Window.activeFocusItem instanceof TextInput,
                   "the keyboard is in the search field")
            keyClick(Qt.Key_Escape)
            tryCompare(shell, "page", "home")
        }

        function test_aTabAlreadyInTheStackIsGoneBackTo() {
            mouseClick(findChild(shell, "tab-library"))
            mouseClick(findChild(shell, "search"))
            mouseClick(findChild(shell, "tab-library"))
            compare(shell.page, "library")
            keyClick(Qt.Key_Escape)
            compare(shell.page, "home", "library was not pushed twice")
        }
    }
}
