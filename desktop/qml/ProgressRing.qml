import QtQuick
import QtQuick.Shapes
import Lumeo

// How much of a download is here, as a ring filling clockwise from the top
// over a faint whole one; in the accent, which marks how much is here.
Shape {
    id: ring

    property real fraction
    property real stroke: 2
    property color color: Theme.accent

    width: 14
    height: 14
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor: "transparent"
        strokeColor: Qt.alpha(Tokens.text, 0.25)
        strokeWidth: ring.stroke
        PathAngleArc {
            centerX: ring.width / 2; centerY: ring.height / 2
            radiusX: (ring.width - ring.stroke) / 2; radiusY: radiusX
            startAngle: 0; sweepAngle: 360
        }
    }
    ShapePath {
        fillColor: "transparent"
        strokeColor: ring.color
        strokeWidth: ring.stroke
        capStyle: ShapePath.RoundCap
        PathAngleArc {
            centerX: ring.width / 2; centerY: ring.height / 2
            radiusX: (ring.width - ring.stroke) / 2; radiusY: radiusX
            startAngle: -90
            sweepAngle: 360 * Math.min(1, Math.max(0, ring.fraction))
        }
    }
}
