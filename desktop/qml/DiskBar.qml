import QtQuick
import Lumeo

// The disk under the downloads as one bar: Lumeo's share in the accent,
// everything else, and what is free.
Rectangle {
    id: bar

    required property Storage storage

    readonly property real total: storage.diskTotal
    readonly property real used: Math.min(storage.used, total)
    readonly property real other: Math.max(total - storage.diskFree, used) - used

    height: 10
    radius: height / 2
    color: Tokens.raised
    clip: true

    Row {
        height: parent.height
        spacing: 2

        Rectangle {
            width: bar.total > 0 ? Math.max(bar.used > 0 ? 3 : 0, bar.used / bar.total * bar.width) : 0
            height: parent.height
            radius: bar.radius
            color: Theme.accent
        }
        Rectangle {
            width: bar.total > 0 ? bar.other / bar.total * bar.width : 0
            height: parent.height
            radius: bar.radius
            color: "#3a3b42"
        }
    }
}
