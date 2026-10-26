pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// The window's pages under the bar, which floats over them. Home is the
// bottom of the stack; Library and Settings are pushed, so Back returns to
// what was being looked at, and a tab already in the stack is gone back to
// rather than pushed again.
FocusScope {
    id: shell

    readonly property string page: stack.currentItem?.objectName ?? ""

    // A download to play: the player takes the window.
    signal watch(string downloadId, string name)

    function place(name) {
        if (name === "home") {
            stack.pop(null)
            return
        }
        const at = stack.find(item => item.objectName === name)
        if (at)
            stack.pop(at)
        else
            stack.push(pages[name])
    }

    function back() {
        if (stack.depth > 1)
            stack.pop()
    }

    // A title's page; [play] starts it there, as the banner's Play does.
    function open(item, play) {
        stack.push(titlePage, {item: item, play: play})
    }

    function search() {
        if (page !== "search")
            stack.push(pages.search)
    }

    readonly property var pages: ({
        library: libraryPage,
        settings: settingsPage,
        search: searchPage,
    })

    // The page the stack changed to takes the keyboard, so a key always has
    // somewhere to go (decisions/testing.md, App tests).
    StackView {
        id: stack
        anchors.fill: parent
        focus: true
        initialItem: homePage
        onCurrentItemChanged: currentItem?.forceActiveFocus()
        // Pages change at once; the bar does not move.
        pushEnter: null
        pushExit: null
        popEnter: null
        popExit: null
        replaceEnter: null
        replaceExit: null
    }

    Bar {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        lit: ["home", "library", "settings"].includes(shell.page) ? shell.page : ""
        canGoBack: stack.depth > 1
        scrolled: (stack.currentItem as ShellPage)?.scrolled ?? false
        onBack: shell.back()
        onPlace: name => shell.place(name)
        onSearch: shell.search()
    }

    // Window shortcuts: they answer wherever the keyboard is.
    Shortcut { sequences: ["Esc", "Alt+Left", "Back"]; enabled: shell.visible; onActivated: shell.back() }
    Shortcut { sequence: "Ctrl+F"; enabled: shell.visible; onActivated: shell.search() }
    TapHandler { acceptedButtons: Qt.BackButton; onTapped: shell.back() }

    // The screens of docs/qt-port.md, step 3, replace these.
    Component { id: homePage; HomePage { objectName: "home"; onOpen: (item, play) => shell.open(item, play) } }
    Component {
        id: titlePage
        TitlePage {
            objectName: "title"
            onWatch: (downloadId, name) => shell.watch(downloadId, name)
            onAddSource: shell.place("settings")
        }
    }
    Component { id: libraryPage; ShellPage { objectName: "library" } }
    Component { id: settingsPage; ShellPage { objectName: "settings" } }
    Component { id: searchPage; Browse { objectName: "search"; topPadding: 68 } }
}
