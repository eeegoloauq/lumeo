import QtQuick
import Lumeo

// On disk, or on its way there: what makes a title play without the swarm.
// [mark] is one of Downloads.marks: {done} or {fraction}.
Rectangle {
    id: badge

    required property var mark

    readonly property bool arriving: mark.fraction !== undefined

    width: 22
    height: 22
    radius: width / 2
    color: "#8c000000"
    Accessible.role: Accessible.Indicator
    Accessible.name: arriving ? qsTrId("downloadsDownloading") : qsTrId("downloadsOnDisk")

    Glyph {
        anchors.centerIn: parent
        visible: !badge.arriving
        glyph: "download"
        size: 14
    }

    ProgressRing {
        anchors.centerIn: parent
        visible: badge.arriving
        fraction: badge.mark.fraction ?? 0
    }
}
