import QtQuick
import QtQuick.Shapes
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

    // A ring that fills as it arrives, over a faint whole one.
    Shape {
        anchors.centerIn: parent
        width: 14
        height: 14
        visible: badge.arriving
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.alpha(Tokens.text, 0.2)
            strokeWidth: 2
            PathAngleArc { centerX: 7; centerY: 7; radiusX: 6; radiusY: 6; startAngle: 0; sweepAngle: 360 }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: Tokens.text
            strokeWidth: 2
            PathAngleArc {
                centerX: 7; centerY: 7; radiusX: 6; radiusY: 6
                startAngle: -90
                sweepAngle: 360 * Math.min(1, Math.max(0, badge.mark.fraction ?? 0))
            }
        }
    }
}
