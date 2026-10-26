pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Lumeo

// The addons the core reads from. Their order breaks ties when two provide
// the same copy, and the first catalogue is the home screen, so each can be
// moved up and down.
SettingsBlock {
    id: block

    // The title whose "Add one" opened Settings: once a source of copies is
    // added, the way back to it is offered.
    property string backTo
    // A source added while there was a title to go back to.
    property string added

    signal back()

    title: qsTrId("settingsSources")
    section: "sources"

    function provides(addon) {
        const resources = addon.resources ?? []
        return [["catalog", qsTrId("settingsAddonCatalog")], ["meta", qsTrId("settingsAddonTitles")],
                ["stream", qsTrId("settingsAddonStreams")], ["subtitles", qsTrId("settingsAddonSubtitles")]]
            .filter(([resource]) => resources.includes(resource)).map(([, words]) => words).join(" · ")
    }

    // Whether each one answers changes behind the page's back.
    Component.onCompleted: Addons.load()

    Connections {
        target: Addons
        function onAdded(addon) {
            address.clear()
            if (block.backTo !== "" && (addon.resources ?? []).includes("stream"))
                block.added = addon.name
        }
    }

    SettingsCard {
        objectName: "addons"

        SettingsWait { visible: !Addons.loaded && Addons.error === "" }
        ErrorRow { message: Addons.error }

        Repeater {
            model: Addons.current
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property string provided: block.provides(modelData)
                readonly property bool failing: (modelData.error ?? "") !== "" && provided === ""
                // Green working, red not answering, grey waiting or off; the
                // words are the dot's tooltip.
                readonly property var health: !modelData.enabled ? [Tokens.muted, qsTrId("settingsSourceOff")]
                    : failing ? [Tokens.down, qsTrId("settingsSourceNotAnswering")]
                    : provided === "" ? [Tokens.muted, qsTrId("settingsSourceWaiting")]
                    : [Tokens.up, qsTrId("settingsSourceWorking")]

                objectName: "addon-" + modelData.id
                width: parent.width
                implicitHeight: content.implicitHeight + 24

                Rectangle {
                    visible: row.index > 0
                    width: parent.width
                    height: 1
                    color: Tokens.divider
                }

                RowLayout {
                    id: content
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                    spacing: 12

                    Column {
                        Layout.fillWidth: true
                        spacing: 3

                        Row {
                            spacing: 8
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: 4
                                color: row.health[0]
                                ToolTip.text: row.health[1]
                                ToolTip.visible: dotHover.hovered
                                HoverHandler { id: dotHover }
                                Accessible.name: row.health[1]
                            }
                            Text {
                                text: row.modelData.name
                                color: Tokens.text
                                font.family: Tokens.fontSans
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }
                        }
                        Text {
                            width: parent.width
                            text: row.failing ? qsTrId("settingsSourceError").arg(row.modelData.error)
                                : row.provided || qsTrId("settingsSourceNotAnsweredYet")
                            color: row.failing ? Tokens.warn : Tokens.muted
                            font.family: Tokens.fontSans
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        // What someone copies to install it elsewhere.
                        TextEdit {
                            width: parent.width
                            readOnly: true
                            selectByMouse: true
                            text: row.modelData.url
                            color: Tokens.muted
                            font.family: "monospace"
                            font.pixelSize: 12
                            wrapMode: TextEdit.WrapAnywhere
                        }
                    }
                    IconButton {
                        objectName: "up"
                        glyph: "chevron_left"
                        rotation: 90
                        tip: qsTrId("settingsSourcesUp")
                        enabled: row.index > 0
                        opacity: enabled ? 1 : 0.3
                        onClicked: Addons.move(row.modelData.id, row.index - 1)
                    }
                    IconButton {
                        objectName: "down"
                        glyph: "chevron_left"
                        rotation: -90
                        tip: qsTrId("settingsSourcesDown")
                        enabled: row.index < Addons.current.length - 1
                        opacity: enabled ? 1 : 0.3
                        onClicked: Addons.move(row.modelData.id, row.index + 1)
                    }
                    SettingSwitch {
                        objectName: "enabled"
                        label: qsTrId("settingsUseAddon").arg(row.modelData.name)
                        checked: row.modelData.enabled
                        onToggled: Addons.setEnabled(row.modelData.id, checked)
                    }
                    IconButton {
                        objectName: "remove"
                        glyph: "close"
                        tone: Tokens.muted
                        tip: qsTrId("commonRemove")
                        onClicked: Addons.remove(row.modelData.id)
                    }
                }
            }
        }

        // The core reads the manifest before it takes an address.
        Item {
            width: parent.width
            implicitHeight: adding.implicitHeight + 28

            Rectangle {
                visible: Addons.current.length > 0
                width: parent.width
                height: 1
                color: Tokens.divider
            }

            Column {
                id: adding
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 6

                RowLayout {
                    width: parent.width
                    spacing: 12

                    TextField {
                        id: address
                        objectName: "address"
                        Layout.fillWidth: true
                        implicitHeight: 36
                        enabled: !Addons.adding
                        placeholderText: qsTrId("settingsAddonAddress")
                        placeholderTextColor: Tokens.muted
                        color: Tokens.text
                        font.family: "monospace"
                        font.pixelSize: 13
                        background: Rectangle {
                            radius: Tokens.radiusControl
                            color: Tokens.page
                            border.color: Addons.addError !== "" ? Tokens.warn
                                : address.activeFocus ? Tokens.dim : Tokens.line
                        }
                        onAccepted: if (text.trim() !== "") Addons.add(text.trim())
                    }
                    RowButton {
                        objectName: "add"
                        text: Addons.adding ? qsTrId("settingsSourcesAsking") : qsTrId("commonAdd")
                        enabled: !Addons.adding && address.text.trim() !== ""
                        onClicked: Addons.add(address.text.trim())
                    }
                }
                Text {
                    visible: Addons.addError !== ""
                    width: parent.width
                    text: Addons.addError
                    color: Tokens.warn
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textData
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    Rectangle {
        objectName: "addedBanner"
        visible: block.added !== ""
        width: parent.width
        height: 56
        radius: Tokens.radiusFloating
        color: Tokens.raised
        border.color: Tokens.line

        RowLayout {
            anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
            spacing: 10

            Glyph { glyph: "check"; color: Tokens.up }
            Text {
                Layout.fillWidth: true
                text: qsTrId("settingsSourceAdded").arg(block.added)
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                elide: Text.ElideRight
            }
            PlayButton {
                objectName: "backTo"
                implicitHeight: 36
                icon.source: ""
                text: qsTrId("settingsBackTo").arg(block.backTo)
                onClicked: block.back()
            }
        }
    }
}
