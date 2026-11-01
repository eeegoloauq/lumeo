import QtQuick
import Lumeo

// What a picture's corner says about its title: seen to the end (an eye) and
// on disk or on its way there (the arrow, or a ring filling in the accent),
// in one pill, so a poster never carries two badges (decisions/interface.md).
Rectangle {
    id: pill

    property bool watched
    // One of Downloads.marks: {done} or {fraction}; undefined for none.
    property var mark

    readonly property bool arriving: mark?.fraction !== undefined
    readonly property bool onDisk: mark !== undefined && !arriving

    visible: watched || mark !== undefined
    width: icons.implicitWidth + 8
    height: 22
    radius: height / 2
    color: "#8c000000"
    Accessible.role: Accessible.Indicator
    Accessible.name: [watched ? qsTrId("libraryWatched") : "",
                      arriving ? qsTrId("downloadsDownloading") : onDisk ? qsTrId("downloadsOnDisk") : ""]
                     .filter(said => said !== "").join(", ")

    Row {
        id: icons
        anchors.centerIn: parent
        spacing: 4

        Glyph {
            objectName: "watchedMark"
            visible: pill.watched
            glyph: "visibility"
            size: 14
        }
        Glyph {
            visible: pill.onDisk
            glyph: "download"
            size: 14
        }
        ProgressRing {
            visible: pill.arriving
            fraction: pill.mark?.fraction ?? 0
        }
    }
}
