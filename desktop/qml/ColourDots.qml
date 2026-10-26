pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// Colours as round swatches, the chosen one ringed and checked; each is
// named by its tooltip.
Row {
    id: dots

    // [{name, colour, tip}]
    required property var colours
    property string selected

    signal picked(string name)

    spacing: 6

    Repeater {
        model: dots.colours
        delegate: AbstractButton {
            id: dot
            required property var modelData
            readonly property string tip: modelData.tip
            objectName: "colour-" + modelData.name
            implicitWidth: 40
            implicitHeight: 40
            checked: dots.selected === modelData.name
            focusPolicy: Qt.TabFocus
            Accessible.role: Accessible.RadioButton
            Accessible.name: tip
            ToolTip.text: tip
            ToolTip.visible: hovered
            ToolTip.delay: 500
            onClicked: dots.picked(modelData.name)
            HoverHandler { cursorShape: Qt.PointingHandCursor }

            background: Rectangle {
                anchors.centerIn: parent
                width: 32
                height: 32
                radius: 16
                color: "transparent"
                border.width: dot.checked || dot.visualFocus ? 2 : 0
                border.color: Tokens.text
            }
            contentItem: Item {
                Rectangle {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    radius: 12
                    color: dot.modelData.colour
                    scale: dot.hovered && !dot.checked ? 1.1 : 1
                    Behavior on scale { NumberAnimation { duration: 120 } }

                    Glyph {
                        anchors.centerIn: parent
                        visible: dot.checked
                        glyph: "check"
                        size: 16
                        color: Tokens.page
                    }
                }
            }
        }
    }
}
