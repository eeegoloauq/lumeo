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
        SettingRow {
            visible: CoreConnection.address !== ""
            label: CoreConnection.address
            Row {
                spacing: 8
                RowButton {
                    objectName: "switchCore"
                    text: CoreConnection.remote ? qsTrId("connectionUseLocal") : qsTrId("connectionUseRemote")
                    onClicked: CoreConnection.remote ? CoreConnection.useLocal() : CoreConnection.useRemote()
                }
                RowButton {
                    objectName: "forgetCore"
                    text: qsTrId("connectionForget")
                    onClicked: CoreConnection.forget()
                }
            }
        }
        // A media server, reached through this machine's core.
        SettingRow {
            visible: CoreConnection.server !== ""
            label: CoreConnection.server
            hint: qsTrId("connectionMediaHint")
            RowButton {
                objectName: "unlinkCore"
                text: qsTrId("connectionForget")
                enabled: !CoreConnection.busy
                onClicked: CoreConnection.unlink()
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
