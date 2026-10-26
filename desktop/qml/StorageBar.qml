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
    readonly property real used: disk.used
    readonly property real other: disk.other

    width: parent?.width ?? 0
    topPadding: 18
    bottomPadding: 14
    spacing: 10
    visible: total > 0
    Accessible.role: Accessible.StaticText
    Accessible.name: [qsTrId("settingsStorageLumeo").arg(Words.bytes(used)),
                      qsTrId("settingsStorageOther").arg(Words.bytes(other)),
                      qsTrId("settingsStorageFree").arg(Words.bytes(storage.diskFree))].join(", ")

    DiskBar { id: disk; width: parent.width; storage: bar.storage }

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
