pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
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
    // A title's trailer to play, as Player.trailer.
    signal trailer(var trailer, string name)

    function place(name) {
        if (name === "home") {
            stack.pop(null)
            return
        }
        const at = stack.find(item => item.objectName === name)
        if (at)
            stack.pop(at)
        else
            stack.push(name === "library" ? library() : pages[name])
    }

    // The library is made once and kept, as home is: made anew, it read its
    // list and asked for every poster again on each visit, and showed as a
    // page filling in. The rest of it starts over when it leaves the stack.
    // Made in the stack at its size, it is laid out at once as a page the
    // stack makes is, and the stack hides it, as one it did not make, when it
    // leaves.
    property LibraryPage kept: null
    function library(): LibraryPage {
        if (!kept)
            kept = libraryPage.createObject(stack, {width: stack.width, height: stack.height}) as LibraryPage
        return kept
    }

    // Settings at its Downloads, where the disk the downloads take is managed.
    function storage() {
        const at = stack.find(item => item.objectName === "settings")
        if (at) {
            stack.pop(at)
            (at as SettingsPage).go("downloads")
        } else {
            stack.push(settingsPage, {section: "downloads"})
        }
    }

    function back() {
        if (stack.depth > 1)
            stack.pop()
    }

    // A title's page; [play] starts it there, as the banner's Play does,
    // and [at], {season, episode}, is the episode it opens on.
    function open(item, play, at) {
        stack.push(titlePage, {item: item, play: !!play, at: at ?? null})
    }

    // A search already in the stack is gone back to, its word kept and
    // selected; otherwise a fresh one.
    function search() {
        const at = stack.find(item => item.objectName === "search")
        if (at) {
            stack.pop(at)
            field.forceActiveFocus()
            field.selectAll()
            return
        }
        finder.open()
        stack.push(pages.search)
    }

    // A line at the foot of whatever page is up.
    function say(text) {
        toast.say(text)
    }

    readonly property var pages: ({
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
        // Search's keyboard is its field, which stands in the bar.
        onCurrentItemChanged: (currentItem?.objectName === "search" ? field : currentItem)?.forceActiveFocus()
        // Pages change at once; the bar does not move.
        pushEnter: null
        pushExit: null
        popEnter: null
        popExit: null
        replaceEnter: null
        replaceExit: null
    }

    Bar {
        id: bar
        anchors { left: parent.left; right: parent.right; top: parent.top }
        tabs: shell.page !== "search"
        lit: ["home", "library", "settings"].includes(shell.page) ? shell.page : ""
        canGoBack: stack.depth > 1
        scrolled: (stack.currentItem as ShellPage)?.scrolled ?? false
        downloads: downloadList
        downloadsOpen: downloadsPanel.opened
        onBack: shell.back()
        onPlace: name => shell.place(name)
        onSearch: shell.search()
        onOpenDownloads: downloadsPanel.opened ? downloadsPanel.close() : downloadsPanel.open()
    }

    DownloadList { id: downloadList }

    // Hangs from the ring, to its left: nothing is to its right.
    DownloadsPanel {
        id: downloadsPanel
        objectName: "downloadsPanel"
        parent: bar.ring
        x: bar.ring.width - width
        y: bar.ring.height + 10
        list: downloadList
        ceiling: shell.height
        onWatch: (downloadId, name) => shell.watch(downloadId, name)
        onOpenTitle: item => shell.open(item, false)
        onStorage: shell.storage()
    }

    // The word and its titles outlive the page: a title opened from it and
    // left again comes back to the same search.
    Search {
        id: finder
        objectName: "finder"
        onPicked: item => shell.open(item, false)
    }

    // Over the bar, where its tabs are while search is the page.
    SearchField {
        id: field
        objectName: "searchField"
        search: finder
        visible: shell.page === "search"
        width: Math.min(640, shell.width - 2 * (Tokens.gutter + 140))
        anchors.horizontalCenter: parent.horizontalCenter
        y: (bar.height - height) / 2
        onDown: (stack.currentItem as SearchPage)?.enter()
    }

    // Also a series marked unwatched, with the way back while the core has
    // not been told.
    Toast {
        id: toast
        held: Viewing.forgetting !== ""
        text: held ? qsTrId("menuMarkedUnwatched") : said
        action: held ? qsTrId("commonUndo") : ""
        onActed: Viewing.undo()
    }

    // The menu every poster and card opens (TitleActions).
    TitleMenu {
        id: titleMenu
        onPlay: (item, at) => shell.open(item, true, at)
        onTrailer: (trailer, name) => shell.trailer(trailer, name)
        onSay: text => toast.say(text)
    }
    Connections {
        target: TitleActions
        function onAsked(target) { titleMenu.show(target) }
    }
    // Which titles are finished, for the eye on every poster: the player
    // marks as it plays, so the window coming back from it asks again.
    Component.onCompleted: Viewing.refresh()
    onVisibleChanged: if (visible) Viewing.refresh()
    Connections {
        target: Viewing
        function onChanged(itemId) { TitleActions.changed(itemId) }
        function onRefused(what) {
            toast.say(what === "hide" ? qsTrId("menuNotHidden")
                    : what === "forget" ? qsTrId("menuNotForgotten") : qsTrId("menuNotMarked"))
        }
    }

    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: shell.visible && Viewing.forgetting !== ""
        onActivated: Viewing.undo()
    }

    // Window shortcuts: they answer wherever the keyboard is.
    Shortcut { sequences: ["Esc", "Alt+Left", "Back"]; enabled: shell.visible && !downloadsPanel.opened; onActivated: shell.back() }
    Shortcut { sequence: "Ctrl+F"; enabled: shell.visible; onActivated: shell.search() }
    TapHandler { acceptedButtons: Qt.BackButton; onTapped: shell.back() }

    Component { id: homePage; HomePage { objectName: "home"; onOpen: (item, play) => shell.open(item, play) } }
    Component {
        id: titlePage
        TitlePage {
            objectName: "title"
            onWatch: (downloadId, name) => shell.watch(downloadId, name)
            onTrailer: (trailer, name) => shell.trailer(trailer, name)
            onAddSource: stack.push(settingsPage, {section: "sources", backTo: item.title})
        }
    }
    Component {
        id: libraryPage
        LibraryPage { objectName: "library"; onOpen: (item, at) => shell.open(item, false, at) }
    }
    Component { id: settingsPage; SettingsPage { objectName: "settings"; onBack: shell.back() } }
    Component {
        id: searchPage
        SearchPage {
            objectName: "search"
            search: finder
            onOpen: item => {
                finder.remember()
                shell.open(item, false)
            }
            onUp: field.forceActiveFocus()
        }
    }
}
