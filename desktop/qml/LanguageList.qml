pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// Languages as chips, best first, and a picker that finds one by its name.
Flow {
    id: list

    // The codes, best first.
    required property var chosen
    // What an empty list means, said in its place.
    property string empty

    signal edited(var codes)

    function nameOf(code) {
        const language = Preferences.languages.find(l => l.code === code)
        return language ? language.name : code.toUpperCase()
    }

    function choose(code) {
        picker.close()
        edited(chosen.concat([code]))
    }

    Layout.fillWidth: true
    spacing: 8

    Text {
        visible: list.chosen.length === 0 && list.empty !== ""
        height: 34
        verticalAlignment: Text.AlignVCenter
        text: list.empty
        color: Tokens.dim
        font.family: Tokens.fontSans
        font.pixelSize: 13
        font.weight: Font.Medium
    }

    Repeater {
        model: list.chosen
        delegate: Rectangle {
            id: chip
            required property string modelData
            objectName: "language-" + modelData
            width: name.implicitWidth + 46
            height: 34
            radius: height / 2
            color: Tokens.raised
            border.color: Tokens.line

            Text {
                id: name
                x: 14
                anchors.verticalCenter: parent.verticalCenter
                text: list.nameOf(chip.modelData)
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 13
                font.weight: Font.Medium
            }
            IconButton {
                objectName: "remove"
                anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
                implicitWidth: 28
                implicitHeight: 28
                glyph: "close"
                glyphSize: 14
                tone: Tokens.muted
                tip: qsTrId("commonRemove")
                onClicked: list.edited(list.chosen.filter(code => code !== chip.modelData))
            }
        }
    }

    AbstractButton {
        id: adder
        objectName: "addLanguage"
        width: addRow.implicitWidth + 28
        height: 34
        focusPolicy: Qt.TabFocus
        Accessible.name: qsTrId("settingsAddLanguage")
        onClicked: picker.open()
        HoverHandler { cursorShape: Qt.PointingHandCursor }

        background: Rectangle {
            radius: height / 2
            color: adder.hovered || picker.visible ? Tokens.hover : "transparent"
            border.width: adder.visualFocus ? 2 : 1
            border.color: adder.visualFocus ? Theme.accent : Tokens.line
        }
        contentItem: Item {
            Row {
                id: addRow
                anchors.centerIn: parent
                spacing: 6
                Glyph { anchors.verticalCenter: parent.verticalCenter; glyph: "add"; size: 16; color: Tokens.dim }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTrId("settingsAddLanguage")
                    color: Tokens.dim
                    font.family: Tokens.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
            }
        }

        Popup {
            id: picker
            y: adder.height + 6
            width: 260
            height: 340
            padding: 6
            focus: true
            onOpened: {
                filter.text = ""
                filter.forceActiveFocus()
            }

            background: Rectangle {
                radius: Tokens.radiusFloating
                color: Tokens.floating
                border.color: Tokens.rim
            }

            contentItem: ColumnLayout {
                spacing: 6

                TextField {
                    id: filter
                    objectName: "filter"
                    Layout.fillWidth: true
                    placeholderText: qsTrId("settingsAddLanguage")
                    placeholderTextColor: Tokens.muted
                    color: Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: 14
                    background: Rectangle {
                        radius: Tokens.radiusControl
                        color: Tokens.surface
                        border.color: filter.activeFocus ? Theme.accent : Tokens.line
                    }
                    // Enter takes the first that matches.
                    onAccepted: if (options.count > 0) list.choose(options.model[0].code)
                    Keys.onDownPressed: options.forceActiveFocus()
                }
                ListView {
                    id: options
                    objectName: "options"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    keyNavigationEnabled: true
                    model: Preferences.languages.filter(l => !list.chosen.includes(l.code)
                        && l.name.toLocaleLowerCase().includes(filter.text.trim().toLocaleLowerCase()))
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: option
                        required property var modelData
                        width: ListView.view.width
                        implicitHeight: 34
                        text: modelData.name
                        font.family: Tokens.fontSans
                        font.pixelSize: 14
                        palette.text: Tokens.text
                        palette.windowText: Tokens.text
                        highlighted: ListView.isCurrentItem && options.activeFocus
                        background: Rectangle {
                            radius: Tokens.radiusControl
                            color: option.hovered || option.highlighted ? Tokens.hover : "transparent"
                        }
                        onClicked: list.choose(modelData.code)
                        Keys.onReturnPressed: list.choose(modelData.code)
                    }
                }
            }
        }
    }
}
