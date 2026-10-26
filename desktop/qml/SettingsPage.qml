pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// Every setting on one page that scrolls, its sections listed beside it: a
// press scrolls there, and the one being read is lit (decisions/interface.md,
// Settings).
ShellPage {
    id: page

    readonly property var sections: ["general", "appearance", "playback", "audioSubtitles", "downloads"]
    readonly property var titles: ({
        general: qsTrId("settingsGeneral"),
        appearance: qsTrId("settingsAppearance"),
        playback: qsTrId("settingsPlayback"),
        audioSubtitles: qsTrId("settingsAudioSubtitles"),
        downloads: qsTrId("settingsDownloads"),
    })
    // The section a preference was last changed from: the core's refusal is
    // said there, not at the top of a page scrolled away.
    property string changedIn

    // Under the bar, which floats over the page.
    readonly property real barHeight: 68
    // The page's column, and the list of sections in its left part.
    readonly property real side: Math.max(Tokens.gutter, (width - 1056) / 2)
    readonly property real nav: 256

    function set(section, key, value) {
        changedIn = section
        Preferences.patch({ [key]: value })
    }

    function sectionOf(key) {
        if (["accent", "episodeArtwork"].includes(key))
            return "appearance"
        if (["askCopy", "nextNotice", "nextCountdown", "seekStep"].includes(key))
            return "playback"
        if (key === "audioLanguages" || key.startsWith("subtitle"))
            return "audioSubtitles"
        if (["keep", "keepDays", "diskLimit", "prefetch", "downloadDir", "uploadLimit", "downloadLimit"].includes(key))
            return "downloads"
        return ""
    }

    // The failure in the section of the preference that was not stored,
    // whoever changed it (the player stores the subtitle size too); else
    // the one changed last, else Appearance.
    function errorIn(section) {
        if (Preferences.error === "")
            return ""
        const owner = Preferences.failedKeys.map(sectionOf).find(s => s !== "")
        return section === (owner ?? (changedIn || "appearance")) ? Preferences.error : ""
    }

    function block(name) {
        return column.children.find(child => child.section === name)
    }

    function go(name) {
        const target = Math.min(block(name).y, Math.max(0, view.contentHeight - view.height + view.topMargin))
        going.to = target - view.topMargin
        going.section = name
        pressed = name
        going.restart()
    }

    // The section whose heading has passed near the top is the one being
    // read; at the very bottom the last, which may be too short ever to get
    // there.
    readonly property string reading: {
        const y = view.contentY + view.topMargin
        if (view.contentY > -view.topMargin && view.atYEnd)
            return sections[sections.length - 1]
        let found = sections[0]
        for (const name of sections) {
            const b = block(name)
            if (b && b.y + b.headingTop - y <= 120)
                found = name
        }
        return found
    }
    // A section pressed in the list stays lit until the page is moved: one
    // too near the end never reaches the top to be read.
    property string pressed
    readonly property string lit: pressed || reading

    scrolled: view.contentY > -view.topMargin

    Flickable {
        id: view
        objectName: "view"
        anchors.fill: parent
        topMargin: page.barHeight
        contentHeight: column.height + 96
        boundsBehavior: Flickable.StopAtBounds
        onContentYChanged: if (!going.running && Math.abs(contentY - going.to) > 1) page.pressed = ""

        WheelScroll { flickable: view }

        Column {
            id: column
            x: page.side + page.nav
            width: Math.min(1056, page.width - 2 * Tokens.gutter) - page.nav

            GeneralSection {}
            AppearanceSection { settings: page }
            PlaybackSection { settings: page }
            AudioSubtitlesSection { settings: page }
            DownloadsSection { settings: page }
        }
    }

    NumberAnimation {
        id: going
        objectName: "going"
        property string section
        target: view
        property: "contentY"
        duration: Theme.panel
        easing.type: Easing.OutCubic
    }

    Column {
        x: page.side
        y: page.barHeight + 50
        width: 200
        spacing: 2

        Text {
            leftPadding: 12
            bottomPadding: 18
            text: qsTrId("settingsTitle")
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: 30
            font.weight: Font.Bold
            font.letterSpacing: -0.4
            Accessible.role: Accessible.Heading
        }
        Repeater {
            model: page.sections
            delegate: AbstractButton {
                id: entry
                required property string modelData
                readonly property bool current: page.lit === modelData
                objectName: "nav-" + modelData
                width: parent.width
                implicitHeight: 34
                leftPadding: 12
                focusPolicy: Qt.TabFocus
                Accessible.role: Accessible.PageTab
                Accessible.name: page.titles[modelData]
                onClicked: page.go(modelData)
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                background: Rectangle {
                    radius: Tokens.radiusControl
                    color: entry.current ? Tokens.raised : entry.hovered ? Tokens.hover : "transparent"
                    border.width: entry.visualFocus ? 2 : 0
                    border.color: Theme.accent
                }
                contentItem: Text {
                    text: page.titles[entry.modelData]
                    verticalAlignment: Text.AlignVCenter
                    color: entry.current ? Tokens.text : Tokens.muted
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textCard
                    font.weight: entry.current ? Font.DemiBold : Font.Normal
                }
            }
        }
    }
}
