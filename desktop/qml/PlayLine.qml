import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// The line under Play: the copy it starts, on disk or a stream, or why
// there is nothing to start and the one thing that can help.
Row {
    id: line

    required property SourceChoice choice

    signal addSource()
    // The line was pressed: the way to another copy.
    signal choose()

    // {icon, text, action, act}: what the line says now.
    readonly property var says: {
        const c = choice
        if (c.upcoming)
            return { text: qsTrId("itemOutDate").arg(Words.shortDate(c.released)) }
        if (c.loading) {
            // A press is answered at once; a look of its own only once it
            // takes long enough to notice, since most lists come from the
            // core's cache within a frame.
            if (c.pending)
                return { text: qsTrId("playerWaitingForSource") }
            return { text: patience.running ? "" : qsTrId("playerLookingForSources") }
        }
        if (c.errorStatus >= 0 && !c.listed)
            return {
                text: c.errorStatus > 0 ? qsTrId("playerCoreCouldNotAsk") : qsTrId("playerCoreNoAnswer"),
                action: qsTrId("commonTryAgain"),
                act: () => c.load()
            }
        if (c.picked < 0) {
            switch (c.empty) {
            case "addons":
                return { text: qsTrId("playerNoSourceAddons"), action: qsTrId("playerAddSource"),
                         act: () => line.addSource() }
            case "failed":
                return { text: c.failed.map(f => Words.providerFailure(f)).join(" · "),
                         action: qsTrId("commonTryAgain"), act: () => c.load() }
            case "today":
                return { text: qsTrId("playerOutTodayNoCopies"), action: qsTrId("commonTryAgain"),
                         act: () => c.load() }
            case "yesterday":
                return { text: qsTrId("playerOutYesterdayNoCopies"), action: qsTrId("commonTryAgain"),
                         act: () => c.load() }
            }
            return { text: qsTrId("playerNoCopies"), action: qsTrId("commonTryAgain"), act: () => c.load() }
        }
        const source = c.sources[c.picked]
        const room = c.noRoom
        // Said where the copy is named, which is also the way to a smaller one.
        if (room.size !== undefined)
            return {
                icon: "error",
                text: qsTrId("playerNoRoomForCopy").arg(Words.bytes(room.size))
                    .arg(room.free > 0 ? Words.bytes(room.free) : qsTrId("settingsGigabytes", 0))
            }
        const onDisk = source.local === "done"
        const what = [Words.sourceTitle(source), source.folder ?? ""].filter(part => part !== "").join(" · ")
        return {
            icon: onDisk ? "check" : "play_circle",
            text: [onDisk ? qsTrId("downloadsOnDisk") : qsTrId("playerStream"), what]
                  .filter(part => part !== "").join(" · ")
        }
    }

    spacing: 12
    height: 32

    Timer {
        id: patience
        interval: 300
        running: line.choice.loading
    }

    // What Play starts, quiet under the buttons beside it: drawn as a
    // button only under the pointer, it opens the way to another copy.
    AbstractButton {
        id: what
        objectName: "playLineChoose"

        readonly property real iconSpace: line.says.icon ? 22 : 0
        readonly property real arrowSpace: arrow.visible ? 20 : 0

        anchors.verticalCenter: parent.verticalCenter
        height: 32
        // As wide as what it says, and no wider than the line leaves it.
        implicitWidth: 4 + iconSpace + label.implicitWidth + 8 + arrowSpace
        width: Math.min(implicitWidth, Math.max(0, line.width - (act.visible ? act.implicitWidth + line.spacing : 0)))
        enabled: line.choice.listed && !line.choice.upcoming
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        onClicked: line.choose()
        ToolTip.text: line.choice.picked >= 0 ? line.choice.sources[line.choice.picked].rawName : ""
        ToolTip.visible: hovered && ToolTip.text !== ""
        ToolTip.delay: 500
        HoverHandler { cursorShape: what.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }

        background: Rectangle {
            radius: height / 2
            color: what.enabled && (what.hovered || what.down) ? Tokens.hover : "transparent"
            border.width: what.visualFocus ? 2 : 0
            border.color: Theme.accent
        }
        contentItem: Item {
            Glyph {
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                visible: !!line.says.icon
                glyph: line.says.icon ?? "check"
                size: 16
                color: Tokens.dim
            }
            Text {
                id: label
                objectName: "playLine"
                x: 4 + what.iconSpace
                anchors.verticalCenter: parent.verticalCenter
                width: what.width - x - 8 - what.arrowSpace
                text: line.says.text
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                elide: Text.ElideRight
            }
            Glyph {
                id: arrow
                anchors { right: parent.right; rightMargin: 2; verticalCenter: parent.verticalCenter }
                visible: what.enabled
                glyph: "arrow_drop_down"
                size: 20
                color: Tokens.dim
            }
        }
    }

    // A pill rather than a button: it sits in a line of small type.
    AbstractButton {
        id: act
        objectName: "playLineAction"
        anchors.verticalCenter: parent.verticalCenter
        visible: !!line.says.action
        implicitHeight: 32
        implicitWidth: actLabel.implicitWidth + 24
        focusPolicy: Qt.TabFocus
        onClicked: line.says.act()

        background: Rectangle {
            radius: height / 2
            color: Tokens.tint
            border.width: act.visualFocus ? 2 : 0
            border.color: Theme.accent
        }
        contentItem: Text {
            id: actLabel
            text: line.says.action ?? ""
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
}
