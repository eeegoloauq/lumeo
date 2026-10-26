import QtQuick
import QtQuick.Controls
import Lumeo

// The line under Play: the copy it starts, on disk or a stream, or why
// there is nothing to start and the one thing that can help.
Row {
    id: line

    required property SourceChoice choice

    signal addSource()

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

    Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Glyph {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!line.says.icon
            glyph: line.says.icon ?? "check"
            size: 16
            color: Tokens.dim
        }
        Text {
            objectName: "playLine"
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, line.width - 200)
            text: line.says.text
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            elide: Text.ElideRight
            ToolTip.text: line.choice.picked >= 0 ? line.choice.sources[line.choice.picked].rawName : ""
            ToolTip.visible: hover.hovered && ToolTip.text !== ""
            ToolTip.delay: 500
            HoverHandler { id: hover }
        }
    }

    // A pill rather than a button: it sits in a line of small type.
    AbstractButton {
        id: act
        objectName: "playLineAction"
        anchors.verticalCenter: parent.verticalCenter
        visible: !!line.says.action
        implicitHeight: 32
        implicitWidth: label.implicitWidth + 24
        focusPolicy: Qt.TabFocus
        onClicked: line.says.act()

        background: Rectangle {
            radius: height / 2
            color: Tokens.tint
            border.width: act.visualFocus ? 2 : 0
            border.color: Theme.accent
        }
        contentItem: Text {
            id: label
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
