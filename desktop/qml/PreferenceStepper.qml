import QtQuick
import QtQuick.Controls
import Lumeo

// A stepped number kept by the core. Each press shows at once and only the
// last of a burst is sent: a reply to an earlier one arriving after a later
// one must not step the display back.
Rectangle {
    id: stepper

    required property int stored
    property int min
    property int max
    property int step: 1
    property var describe: n => String(n)
    property string lessTip
    property string moreTip
    property real valueWidth: 80

    signal chosen(int value)

    property var held
    readonly property int shown: held ?? stored

    function go(by) {
        held = Math.max(min, Math.min(shown + by, max))
        burst.restart()
    }

    implicitWidth: row.implicitWidth
    implicitHeight: 36
    radius: Tokens.radiusControl
    color: Tokens.surface
    border.color: Tokens.line

    Timer {
        id: burst
        interval: 400
        onTriggered: stepper.chosen(stepper.held)
    }
    // Once sent, what the core holds is the truth again: the new value, or
    // the old one beside its refusal.
    Connections {
        target: Preferences
        function onChanged() { if (!burst.running) stepper.held = undefined }
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter

        IconButton {
            objectName: "less"
            implicitWidth: 36
            implicitHeight: 36
            glyph: "remove"
            opacity: enabled ? 1 : 0.35
            tip: stepper.lessTip
            enabled: stepper.shown > stepper.min
            onClicked: stepper.go(-stepper.step)
        }
        Text {
            width: stepper.valueWidth
            anchors.verticalCenter: parent.verticalCenter
            text: stepper.describe(stepper.shown)
            horizontalAlignment: Text.AlignHCenter
            color: Tokens.text
            font.family: Tokens.fontSans
            font.pixelSize: 13
            font.weight: Font.Medium
        }
        IconButton {
            objectName: "more"
            implicitWidth: 36
            implicitHeight: 36
            glyph: "add"
            opacity: enabled ? 1 : 0.35
            tip: stepper.moreTip
            enabled: stepper.shown < stepper.max
            onClicked: stepper.go(stepper.step)
        }
    }
}
