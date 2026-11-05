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
        navigation: Navigation {}
    }

    Component {
        id: another
        Shell { anchors.fill: parent; navigation: Navigation {} }
    }

    // A shell over a navigation the test keeps, as the window keeps it.
    Component { id: navigationComponent; Navigation {} }
    Component { id: over; Shell { anchors.fill: parent } }
    Component { id: windowComponent; Main {} }

    TestCase {
        name: "Shell"
        when: windowShown

        function cleanup() {
            shell.visible = true
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
            mouseClick(findChild(shell, "tab-settings"))
            mouseClick(findChild(shell, "tab-library"))
            compare(shell.page, "library")
            keyClick(Qt.Key_Escape)
            compare(shell.page, "home", "library was not pushed twice")
        }

        // A toast was one line however long, and a long one ran off both
        // sides of the window.
        function test_aLongLineWrapsInsideTheWindow() {
            const toast = findChild(shell, "toast")
            shell.say("A line far too long to stand on one row of the window. ".repeat(8))
            verify(toast.visible)
            verify(toast.x >= 24 && toast.x + toast.width <= shell.width - 24,
                   "inside the window: " + toast.x + " " + toast.width)
            verify(findChild(toast, "toastText").lineCount > 1, "wrapped")
        }

        // A title from a link or a file was pushed every time and stayed made
        // until Back passed it, one more page for every link followed.
        function test_aTitleFromOutsideGivesWayToTheNextOne() {
            const film = id => ({ id: id, kind: "movie", title: id, year: 1950 })
            const shown = () => findChild(shell, "title")?.item.id
            shell.openFromOutside(film("tt1"))
            shell.openFromOutside(film("tt2"))
            compare(shown(), "tt2")
            keyClick(Qt.Key_Escape)
            compare(shell.page, "home", "the first gave way")

            // Opened inside, it is the viewer's to go back to.
            shell.open(film("tt3"), false)
            shell.openFromOutside(film("tt4"))
            keyClick(Qt.Key_Escape)
            compare(shown(), "tt3")
        }

        // The shell goes while the window is in the background, and comes
        // back where the viewer was: the top page made at once, the ones under
        // it as Back reaches them, and a title opened with Play not started
        // again.
        function test_aShellMadeAgainComesBackWhereTheViewerWas() {
            const navigation = createTemporaryObject(navigationComponent, window)
            let made = over.createObject(window, { navigation: navigation })
            shell.visible = false
            made.forceActiveFocus()
            mouseClick(findChild(made, "tab-settings"))
            made.open({ id: "tt1", kind: "movie", title: "Nosferatu", year: 1922 }, true)
            compare(made.page, "title")
            verify(findChild(made, "title").play, "Play pressed on the way")
            let gone = false
            made.Component.destruction.connect(() => gone = true)
            made.destroy()
            tryVerify(() => gone)

            made = over.createObject(window, { navigation: navigation })
            made.forceActiveFocus()
            compare(made.page, "title")
            const page = findChild(made, "title")
            compare(page.item.id, "tt1")
            verify(!page.play, "not started again")
            verify(!findChild(made, "settings"), "the page under it not made yet")
            keyClick(Qt.Key_Escape)
            compare(made.page, "settings")
            keyClick(Qt.Key_Escape)
            compare(made.page, "home")
            made.destroy()
        }

        // A title page under another kept its banner, decoded at the
        // screen's width, for every page in the stack.
        function test_aTitleUnderAnotherPageLetsGoOfItsBanner() {
            const film = id => ({ id: id, kind: "movie", title: id, year: 1950, background: "https://example.com/" + id + ".jpg" })
            shell.open(film("tt1"), false)
            const under = findChild(shell, "title")
            const art = findChild(under, "bannerArt")
            verify(art.source.toString() !== "", "the banner shown")
            shell.open(film("tt2"), false)
            compare(art.source.toString(), "", "let go under the next page")
            keyClick(Qt.Key_Escape)
            verify(findChild(shell, "title") === under)
            verify(art.source.toString() !== "", "back with Back")
        }

        // Hidden to the background, the window kept every page, its pictures
        // and its bindings; now it keeps where they were.
        function test_theWindowAwayKeepsNoPages() {
            const away = createTemporaryObject(windowComponent, null)
            tryVerify(() => away.visible && !!away.shell, 5000, "the window up")
            away.shell.place("settings")
            away.hide()
            tryVerify(() => !away.shell, 2000, "no pages while away")
            away.show()
            tryVerify(() => !!away.shell, 2000, "the pages back")
            compare(away.shell.page, "settings")
            away.shell.back()
            compare(away.shell.page, "home")
            // The test's window takes the keys back.
            away.hide()
            window.Window.window.requestActivate()
            tryVerify(() => window.Window.active, 2000, "the test's window active")
        }

        // A window chosen to open on My list opens there, with Home under it
        // as after its tab.
        function test_theWindowOpensOnTheStartPage() {
            LocalSettings.startPage = "list"
            const started = createTemporaryObject(another, window)
            LocalSettings.startPage = "home"
            compare(started.page, "library")
            compare(findChild(started, "library").section, "list")
            // Two shells' Escape would be ambiguous, and neither answers.
            shell.visible = false
            started.forceActiveFocus()
            keyClick(Qt.Key_Escape)
            shell.visible = true
            compare(started.page, "home")
        }
    }
}
