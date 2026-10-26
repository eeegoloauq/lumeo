import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// Downloads in the bar, always in the same place: a plain arrow at rest, a
// ring filling while anything arrives and left empty while nobody sends, a
// solid disk once all that is listed is on disk.
ToolButton {
    id: button

    required property DownloadList list
    property bool open

    implicitWidth: 34
    implicitHeight: 34
    padding: 0
    focusPolicy: Qt.TabFocus
    Accessible.name: ToolTip.text
    ToolTip.text: list.running > 0 ? qsTrId("downloadsRunningTooltip", list.running).arg(Math.round(list.fraction * 100))
                                   : qsTrId("settingsDownloads")
    ToolTip.visible: hovered
    ToolTip.delay: 500

    background: Rectangle {
        radius: height / 2
        color: button.open ? Tokens.tint : button.down || button.hovered ? Tokens.hover : "transparent"
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }

    contentItem: Item {
        Glyph {
            anchors.centerIn: parent
            visible: button.list.ring === "rest"
            glyph: "download"
            size: 22
            color: Tokens.dim
        }
        ProgressRing {
            anchors.centerIn: parent
            visible: button.list.ring === "arriving" || button.list.ring === "stalled"
            width: 22
            height: 22
            fraction: button.list.ring === "arriving" ? button.list.fraction : 0
        }
        Rectangle {
            anchors.centerIn: parent
            visible: button.list.ring === "done"
            width: 22
            height: 22
            radius: 11
            color: Theme.accent
        }
        Glyph {
            anchors.centerIn: parent
            visible: button.list.ring !== "rest"
            glyph: "download"
            size: 13
            color: button.list.ring === "done" ? Tokens.page
                 : button.list.ring === "stalled" ? Qt.alpha(Tokens.text, 0.6) : Tokens.text
        }
    }
}
