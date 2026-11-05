pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// The window's pages under the bar, which floats over them, as the
// navigation has them: Home is the bottom of the stack and the tabs are
// pushed, so Back returns to what was being looked at. The shell goes while
// the window is in the background (Main), and is made again where the
// navigation was.
FocusScope {
    id: shell

    // Where the pages are and what they are made from; it outlives the shell.
    required property Navigation navigation

    readonly property string page: stack.currentItem?.objectName ?? ""

    // A download to play: the player takes the window.
    signal watch(string downloadId, string name)
    // A title's trailer to play, as Player.trailer.
    signal trailer(var trailer, string name)

    function place(name) {
        navigation.go({page: name})
    }

    // Settings at its Downloads, where the disk the downloads take is managed.
    function storage() {
        const kept = navigation.find("settings") >= 0
        navigation.go({page: "settings", section: "downloads"})
        if (kept)
            (stack.currentItem as SettingsPage).go("downloads")
    }

    function back() {
        navigation.back()
    }

    // A title's page; [play] starts it there, as the banner's Play does,
    // and [at], {season, episode}, is the episode it opens on.
    function open(item, play, at) {
        navigation.open({page: "title", item: item, play: !!play, at: at ?? null})
    }

    // A title from a link or a file opened outside the app.
    function openFromOutside(item) {
        navigation.openFromOutside(item)
    }

    // A search already in the stack is gone back to, its word kept and
    // selected; otherwise a fresh one.
    function search() {
        if (navigation.find("search") >= 0) {
            navigation.go({page: "search"})
            field.forceActiveFocus()
            field.selectAll()
            return
        }
        finder.open()
        navigation.open({page: "search"})
    }

    // A line at the foot of whatever page is up.
    function say(text) {
        toast.say(text)
    }

    // The page [place] is made from, and what it is made with.
    function made(place) {
        switch (place.page) {
        case "title": return [titlePage, {item: place.item, play: !!place.play, at: place.at ?? null}]
        case "library": return [libraryPage, {}]
        case "settings": return [settingsPage, {section: place.section ?? "", backTo: place.backTo ?? ""}]
        case "search": return [searchPage, {}]
        }
        return []
    }

    // The stack as the navigation has it, its first [kept] pages as they
    // were. Of several new pages only the top one is made: the stack makes
    // each under it when Back reaches it.
    function follow(kept) {
        if (stack.depth > kept) {
            if (navigation.depth === kept) {
                stack.popToIndex(kept - 1)
                return
            }
            if (stack.depth > kept + 1)
                stack.popToIndex(kept)
            const [page, properties] = made(navigation.at(kept))
            stack.replaceCurrentItem(page, properties)
            ++kept
        }
        let above = []
        for (let i = kept; i < navigation.depth; ++i)
            above = above.concat(made(navigation.at(i)))
        if (above.length > 0)
            stack.pushItems(above)
    }

    Connections {
        target: shell.navigation
        function onMoved(kept) { shell.follow(kept) }
    }

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

    // The word and its titles outlive the page, and the shell: a title
    // opened from it and left again comes back to the same search.
    readonly property Search finder: navigation.search
    Connections {
        target: shell.finder
        function onPicked(item) { shell.open(item, false) }
    }

    // Over the bar, where its tabs are while search is the page.
    SearchField {
        id: field
        objectName: "searchField"
        search: shell.finder
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
    Component.onCompleted: {
        Viewing.refresh()
        follow(1)
    }
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

    // Home stays made under the other pages, as the one Back always ends at
    // and the one most often gone back to: about a screen of shelves and its
    // banner at the screen's width (decisions/performance.md).
    Component {
        id: homePage
        HomePage {
            objectName: "home"
            home: shell.navigation.home
            onOpen: (item, play) => shell.open(item, play)
        }
    }
    Component {
        id: titlePage
        TitlePage {
            objectName: "title"
            onWatch: (downloadId, name) => shell.watch(downloadId, name)
            onTrailer: (trailer, name) => shell.trailer(trailer, name)
            onAddSource: shell.navigation.open({page: "settings", section: "sources", backTo: item.title})
        }
    }
    Component {
        id: libraryPage
        LibraryPage {
            objectName: "library"
            list: shell.navigation.list
            onOpen: (item, at) => shell.open(item, false, at)
        }
    }
    Component { id: settingsPage; SettingsPage { objectName: "settings"; onBack: shell.back() } }
    Component {
        id: searchPage
        SearchPage {
            objectName: "search"
            search: shell.finder
            onOpen: item => {
                shell.finder.remember()
                shell.open(item, false)
            }
            onUp: field.forceActiveFocus()
        }
    }
}
