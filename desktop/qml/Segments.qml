pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// One of a few, in a strip: the chosen one lit white, the one bright thing
// in the row. A value that is none of them lights nothing.
Rectangle {
    id: strip

    // [{value, label, tip}]
    required property var choices
    property var selected

    signal picked(var value)

    implicitWidth: buttons.implicitWidth + 6
    implicitHeight: 36
    radius: height / 2
    color: Tokens.surface
    border.color: Tokens.line

    Row {
        id: buttons
        anchors.centerIn: parent

        Repeater {
            model: strip.choices
            delegate: AbstractButton {
                id: segment
                required property var modelData
                objectName: "segment-" + modelData.value
                implicitHeight: strip.height - 6
                implicitWidth: label.implicitWidth + 32
                checked: strip.selected === modelData.value
                focusPolicy: Qt.TabFocus
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.label
                ToolTip {
                    text: segment.modelData.tip ?? ""
                    visible: segment.hovered && !!segment.modelData.tip
                }
                onClicked: strip.picked(modelData.value)
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                background: Rectangle {
                    radius: height / 2
                    color: segment.checked ? Tokens.text : segment.hovered ? Tokens.hover : "transparent"
                    border.width: segment.visualFocus ? 2 : 0
                    border.color: Theme.accent
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                contentItem: Text {
                    id: label
                    text: segment.modelData.label
                    color: segment.checked ? Tokens.page : Tokens.dim
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.family: Tokens.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
            }
        }
    }
}
