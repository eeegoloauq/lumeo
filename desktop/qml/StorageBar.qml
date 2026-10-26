pragma ComponentBehavior: Bound

import QtQuick
import Lumeo

// The disk as one bar: Lumeo's share in the accent, everything else, and
// what is free; the limit, when there is one, said beside Lumeo's share.
Column {
    id: bar

    required property Storage storage
    property real limit

    readonly property real total: storage.diskTotal
    readonly property real used: Math.min(storage.used, total)
    readonly property real other: Math.max(total - storage.diskFree, used) - used

    width: parent?.width ?? 0
    topPadding: 18
    bottomPadding: 14
    spacing: 10
    visible: total > 0
    Accessible.role: Accessible.StaticText
    Accessible.name: [qsTrId("settingsStorageLumeo").arg(Words.bytes(used)),
                      qsTrId("settingsStorageOther").arg(Words.bytes(other)),
                      qsTrId("settingsStorageFree").arg(Words.bytes(storage.diskFree))].join(", ")

    Rectangle {
        width: parent.width
        height: 10
        radius: 5
        color: Tokens.raised
        clip: true

        Row {
            height: parent.height
            spacing: 2

            Rectangle {
                width: bar.total > 0 ? Math.max(bar.used > 0 ? 3 : 0, bar.used / bar.total * bar.width) : 0
                height: parent.height
                radius: 5
                color: Theme.accent
            }
            Rectangle {
                width: bar.total > 0 ? bar.other / bar.total * bar.width : 0
                height: parent.height
                radius: 5
                color: "#3a3b42"
            }
        }
    }

    Row {
        spacing: 20

        Text {
            text: qsTrId("settingsStorageLumeo").arg(Words.bytes(bar.used))
                  + (bar.limit > 0 ? qsTrId("settingsStorageOf").arg(Words.bytes(bar.limit)) : "")
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
        Text {
            text: qsTrId("settingsStorageOther").arg(Words.bytes(bar.other))
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: 12
        }
        Text {
            text: qsTrId("settingsStorageFree").arg(Words.bytes(bar.storage.diskFree))
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: 12
        }
    }
}
