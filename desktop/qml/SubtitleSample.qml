import QtQuick
import QtQuick.Shapes
import Lumeo

// A sample line drawn the way the subtitle choices would have mpv draw it:
// the same size, outline, shadow and box in mpv's 720-line scale, twice true
// to scale (a line in a sample this small is too small to judge), in our
// font rather than the system's sans.
Rectangle {
    id: sample

    required property var preferences

    readonly property string background: preferences.subtitleBackground ?? "none"
    readonly property real unit: height / 720 * 2 * (preferences.subtitleScale ?? 1)
    // libass sizes a font by its ascent plus descent rather than its em, and
    // that line is 1.395 em of IBM Plex Sans.
    readonly property real pixelSize: SubtitleStyle.fontSize * unit / 1.395
    readonly property real outline: SubtitleStyle.border(background) * unit
    readonly property real shadow: background === "shadow" ? SubtitleStyle.shadow * unit : 0
    // Below the picture is off the sample: it sits on the bottom edge.
    readonly property real lift: Math.max(0, Math.min(100 - (preferences.subtitlePosition ?? 100), 100)) / 100 * height
    readonly property color colour: SubtitleStyle.colours.find(c => c.name === preferences.subtitleColor)?.colour
                                    ?? SubtitleStyle.colours[0].colour

    width: parent?.width ?? 0
    height: 180
    radius: Tokens.radiusFloating
    clip: true
    gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: "#4a4740" }
        GradientStop { position: 1; color: "#26272b" }
    }
    Accessible.ignored: true

    TextMetrics {
        id: metrics
        font.family: Tokens.fontSans
        font.pixelSize: sample.pixelSize
        text: qsTrId("settingsSubtitlePreview")
    }

    Item {
        id: line
        width: metrics.advanceWidth
        height: metrics.height
        x: (sample.width - width) / 2
        y: sample.height - sample.height * SubtitleStyle.margin / 720 - sample.lift - height

        // The box stands in for the outline and the shadow.
        Rectangle {
            visible: sample.background === "box"
            anchors.fill: parent
            anchors.margins: -sample.outline
            color: SubtitleStyle.boxColour
        }

        // mpv's outline is a stroke twice the border wide on the glyph's
        // edge; the shadow is that outlined shape again, moved down and right.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeWidth: sample.background === "shadow" ? sample.outline * 2 : -1
                strokeColor: "black"
                fillColor: sample.background === "shadow" ? "black" : "transparent"
                joinStyle: ShapePath.RoundJoin
                PathText { x: sample.shadow; y: sample.shadow; font: metrics.font; text: metrics.text }
            }
            ShapePath {
                strokeWidth: sample.background === "box" ? -1 : sample.outline * 2
                strokeColor: "black"
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                PathText { font: metrics.font; text: metrics.text }
            }
            ShapePath {
                strokeWidth: -1
                fillColor: sample.colour
                PathText { font: metrics.font; text: metrics.text }
            }
        }
    }
}
