import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Lumeo

// Download as one round icon, with what it means in words in the tooltip:
// an arrow; a ring filling while it arrives; a solid disk with the arrow
// knocked out once all of it is here.
AbstractButton {
    id: button

    property string tip
    // How far it has got while it runs; negative while nothing runs.
    property real fraction: -1
    property bool done

    readonly property bool running: fraction >= 0

    implicitWidth: 36
    implicitHeight: 36
    focusPolicy: Qt.TabFocus
    enabled: !done && !running
    Accessible.name: tip
    ToolTip.text: tip
    ToolTip.visible: hover.hovered && tip !== ""
    ToolTip.delay: 500
    // Hovered even when it cannot be pressed: the tooltip says why.
    HoverHandler { id: hover; cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }

    background: Rectangle {
        radius: width / 2
        color: button.down ? Qt.lighter(Tokens.tint, 1.4) : Tokens.tint
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
    contentItem: Item {
        Glyph {
            anchors.centerIn: parent
            visible: !button.done && !button.running
            glyph: "download"
            size: 20
        }
        Rectangle {
            anchors.centerIn: parent
            width: 20
            height: 20
            radius: 10
            visible: button.done
            color: Tokens.text

            Glyph { anchors.centerIn: parent; glyph: "download"; size: 12; color: Tokens.page }
        }
        Shape {
            anchors.centerIn: parent
            width: 20
            height: 20
            visible: button.running
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(Tokens.text, 0.2)
                strokeWidth: 2
                PathAngleArc { centerX: 10; centerY: 10; radiusX: 9; radiusY: 9; startAngle: 0; sweepAngle: 360 }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: Tokens.text
                strokeWidth: 2
                PathAngleArc {
                    centerX: 10; centerY: 10; radiusX: 9; radiusY: 9
                    startAngle: -90
                    sweepAngle: 360 * Math.min(1, Math.max(0, button.fraction))
                }
            }
        }
        Glyph {
            anchors.centerIn: parent
            visible: button.running
            glyph: "download"
            size: 12
        }
    }
}
