pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

SettingsBlock {
    title: qsTrId("settingsGeneral")
    section: "general"

    SettingsCard {
        SettingRow {
            label: qsTrId("settingsLanguage")

            // Each language in itself; one the system asks for with no
            // translation reads as English.
            ComboBox {
                id: language
                objectName: "language"
                implicitWidth: 200
                implicitHeight: 36
                model: LocalSettings.languages
                textRole: "name"
                valueRole: "code"
                currentIndex: count > 0 ? Math.max(indexOfValue(Qt.locale().name.split("_")[0]), indexOfValue("en")) : -1
                font.family: Tokens.fontSans
                font.pixelSize: 14
                onActivated: LocalSettings.language = currentValue
                background: Rectangle {
                    radius: Tokens.radiusControl
                    color: language.hovered ? Tokens.raised : Tokens.surface
                    border.width: language.visualFocus ? 2 : 1
                    border.color: language.visualFocus ? Theme.accent : Tokens.line
                }
                popup.background: Rectangle {
                    radius: Tokens.radiusControl
                    color: Tokens.floating
                    border.color: Tokens.rim
                }
            }
        }
        SettingRow {
            label: qsTrId("settingsStartPage")

            Segments {
                objectName: "startPage"
                choices: [
                    { value: "home", label: qsTrId("homeTitle") },
                    { value: "list", label: qsTrId("libraryMyList") },
                ]
                selected: LocalSettings.startPage
                onPicked: value => LocalSettings.startPage = value
            }
        }
        SettingRow {
            visible: Background.available
            label: qsTrId("settingsBackground")
            SettingSwitch {
                objectName: "background"
                label: qsTrId("settingsBackground")
                checked: LocalSettings.background
                onToggled: LocalSettings.background = checked
            }
        }
        SettingRow {
            visible: Background.available
            label: qsTrId("settingsAutostart")
            SettingSwitch {
                objectName: "autostart"
                label: qsTrId("settingsAutostart")
                checked: LocalSettings.autostart
                onToggled: LocalSettings.autostart = checked
            }
        }
    }

    SettingsCard {
        visible: !CoreConnection.overridden
        SettingRow {
            label: qsTrId("connectionCore")
            RowButton {
                objectName: "connectCore"
                text: qsTrId("connectionConnect")
                onClicked: pairing.open()
            }
        }
        // This computer and every saved server; the one used from the next
        // start says so and has no Use button.
        SettingRow {
            visible: CoreConnection.servers.length > 0
            label: qsTrId("connectionThisComputer")
            hint: CoreConnection.selected === "" ? qsTrId("connectionSelected") : ""
            RowButton {
                objectName: "useThisComputer"
                visible: CoreConnection.selected !== ""
                text: qsTrId("connectionUse")
                enabled: !CoreConnection.busy
                onClicked: CoreConnection.use("")
            }
        }
        Repeater {
            model: CoreConnection.servers
            SettingRow {
                id: server
                required property var modelData
                readonly property bool selected: modelData.address === CoreConnection.selected && modelData.media === CoreConnection.selectedMedia
                label: modelData.address
                hint: [selected ? qsTrId("connectionSelected") : "",
                       modelData.media ? qsTrId("connectionMediaHint") : ""].filter(line => line !== "").join("\n")
                Row {
                    spacing: 8
                    RowButton {
                        objectName: "useCore"
                        visible: !server.selected
                        text: qsTrId("connectionUse")
                        enabled: !CoreConnection.busy
                        onClicked: CoreConnection.use(server.modelData.address, server.modelData.media)
                    }
                    RowButton {
                        objectName: "forgetCore"
                        text: qsTrId("connectionForget")
                        enabled: !CoreConnection.busy
                        onClicked: CoreConnection.forget(server.modelData.address, server.modelData.media)
                    }
                }
            }
        }
        SettingRow {
            visible: CoreConnection.restartNeeded
            label: qsTrId("connectionRestartHint")
            RowButton {
                objectName: "restartCore"
                text: qsTrId("connectionRestart")
                onClicked: Instance.restart()
            }
        }
        ErrorRow { message: CoreConnection.error }
    }

    // What is the viewer's own, carried to another core as a file.
    SettingsCard {
        id: personalCard

        // What the last export or import did; cleared as the next starts.
        property string outcome

        SettingRow {
            label: qsTrId("personalData")
            hint: qsTrId("personalHint")
            Row {
                spacing: 8
                RowButton {
                    objectName: "exportPersonal"
                    text: qsTrId("personalExport")
                    enabled: !personal.busy
                    onClicked: Desktop.pickSaveFile(qsTrId("personalExportTitle"),
                                                    "lumeo-" + Qt.formatDate(new Date(), "yyyy-MM-dd") + ".json",
                                                    path => { personalCard.outcome = ""; personal.exportTo(path) })
                }
                RowButton {
                    objectName: "importPersonal"
                    text: qsTrId("personalImport")
                    enabled: !personal.busy
                    onClicked: Desktop.pickFile(qsTrId("personalImportTitle"),
                                                path => { personalCard.outcome = ""; personal.importFrom(path) })
                }
            }
        }
        SettingRow {
            objectName: "personalOutcome"
            visible: personalCard.outcome !== ""
            label: personalCard.outcome
        }
        ErrorRow { message: personal.error }

        PersonalData {
            id: personal
            onExported: personalCard.outcome = qsTrId("personalSaved")
            onImported: written => personalCard.outcome = written > 0 ? qsTrId("personalImported", written)
                                                              : qsTrId("personalNothingNew")
        }
    }

    ConnectionDialog { id: pairing }
}
