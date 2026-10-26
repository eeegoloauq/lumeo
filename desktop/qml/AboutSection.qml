pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Lumeo

// What is running, whether the core answers, what this machine decodes, and
// what a bug report needs.
SettingsBlock {
    id: block

    required property var settings

    // Kept to codecs a catalogue copy is likely to use.
    readonly property var video: ["h264", "hevc", "av1", "vp9"]
    readonly property var audio: ["aac", "ac3", "eac3", "dts", "truehd"]
    readonly property var broken: MpvFacts.answered
        ? video.filter(codec => MpvFacts.unreliable(codec) !== "")
               .map(codec => qsTrId("playerDecoderBroken").arg(codec).arg(MpvFacts.unreliable(codec)))
        : []
    readonly property string version: Qt.application.version || "dev"
    readonly property string player: [MpvFacts.version ? qsTrId("settingsMpvVersion").arg(MpvFacts.version) : "",
                                      MpvFacts.hardware].filter(part => part !== "").join(" · ")

    // Everything a report needs, in one paste.
    function details() {
        const status = coreStatus.answering ? qsTrId("commonAnswering") : qsTrId("commonNotAnswering")
        const missing = video.concat(audio).filter(codec => MpvFacts.has(codec) === 0)
        const mpv = MpvFacts.version || qsTrId("commonUnknown")
        return [
            qsTrId("settingsDetailsLumeo").arg(version),
            coreStatus.providers >= 0
                ? qsTrId("settingsDetailsCoreProviders", coreStatus.providers).arg(coreStatus.address).arg(status)
                : qsTrId("settingsDetailsCore").arg(coreStatus.address).arg(status),
            MpvFacts.hardware ? qsTrId("settingsDetailsPlayerHardware").arg(mpv).arg(MpvFacts.hardware)
                              : qsTrId("settingsDetailsPlayer").arg(mpv),
            qsTrId("settingsDetailsSystem").arg(Desktop.system).arg(""),
        ].concat(missing.length ? [qsTrId("settingsDetailsMissingDecoder").arg(missing.join(", "))] : [])
         .concat(broken)
         .concat([coreStatus.logPath ? qsTrId("settingsDetailsLogsCore").arg(Desktop.playerLog).arg(coreStatus.logPath)
                                     : qsTrId("settingsDetailsLogs").arg(Desktop.playerLog)])
         .map(line => line.trim()).join("\n")
    }

    title: qsTrId("settingsAbout")
    section: "about"

    CoreStatus { id: coreStatus }

    SettingsCard {
        SettingRow {
            label: "Lumeo"
            Value { text: block.version }
            RowButton {
                visible: Releases.notes.length > 0
                text: qsTrId("releaseWhatsNew")
                onClicked: whatsNew.open()
            }
            Popup {
                id: whatsNew
                parent: Overlay.overlay
                anchors.centerIn: parent
                margins: Theme.edge
                modal: true
                padding: 0
                background: null
                contentItem: ReleaseCard {
                    title: qsTrId("releaseUpdatedTo").arg(block.version)
                    items: Releases.notes
                    action: qsTrId("releaseGotIt")
                    onActed: whatsNew.close()
                    onClosed: whatsNew.close()
                }
            }
        }
        // The core asks, not the client: every call leaving the machine is
        // the core's (decisions/shipping.md).
        SettingRow {
            visible: Preferences.current.checkUpdates !== undefined
            label: qsTrId("settingsCheckUpdates")
            SettingSwitch {
                objectName: "checkUpdates"
                label: qsTrId("settingsCheckUpdates")
                checked: Preferences.current.checkUpdates ?? false
                onToggled: block.settings.set(block.section, "checkUpdates", checked)
            }
        }
        SettingRow {
            visible: !!Preferences.current.checkUpdates
            label: qsTrId("settingsBetaUpdates")
            SettingSwitch {
                objectName: "betaUpdates"
                label: qsTrId("settingsBetaUpdates")
                checked: !!Preferences.current.betaUpdates
                onToggled: block.settings.set(block.section, "betaUpdates", checked)
            }
        }
        SettingRow {
            label: qsTrId("settingsCore")
            hint: coreStatus.providers > 0 ? qsTrId("settingsProviderCount", coreStatus.providers) : ""

            Rectangle {
                width: 8
                height: 8
                radius: 4
                color: coreStatus.asking ? Tokens.muted : coreStatus.answering ? Tokens.up : Tokens.down
            }
            Value { text: coreStatus.address; font.family: "monospace" }
            Value {
                text: coreStatus.asking ? qsTrId("commonAsking")
                    : coreStatus.answering ? qsTrId("commonAnswering") : qsTrId("commonNotAnswering")
                color: coreStatus.asking ? Tokens.muted : coreStatus.answering ? Tokens.up : Tokens.down
            }
            RowButton {
                visible: !coreStatus.asking && !coreStatus.answering
                text: qsTrId("commonTryAgain")
                onClicked: coreStatus.load()
            }
        }
        ErrorRow { message: coreStatus.error }
        SettingRow {
            visible: coreStatus.providers === 0
            label: qsTrId("settingsSourceProviders")
            Value { text: qsTrId("settingsNoProviders"); color: Tokens.warn }
        }
        SettingRow {
            label: qsTrId("settingsPlayer")
            hint: MpvFacts.version && !MpvFacts.hardware ? qsTrId("settingsHardwareDecoderHint") : ""
            Value { text: block.player || (MpvFacts.answered ? qsTrId("settingsMpvNoAnswer") : "…") }
        }
    }

    SettingsCard {
        SettingRow {
            label: qsTrId("settingsPicture")
            Codecs { codecs: block.video }
        }
        SettingRow {
            label: qsTrId("settingsSound")
            Codecs { codecs: block.audio }
        }
        Repeater {
            model: block.broken
            delegate: SettingRow {
                id: warning
                required property string modelData
                label: qsTrId("settingsWarning")
                Value { text: warning.modelData; color: Tokens.warn; Layout.maximumWidth: 480; wrapMode: Text.Wrap }
            }
        }
        // Printed for the viewer, never run on their behalf.
        SettingRow {
            visible: block.broken.length > 0 && MpvFacts.installCommands.length > 0
            label: qsTrId("settingsHowToFix")

            TextEdit {
                readOnly: true
                selectByMouse: true
                text: MpvFacts.installCommands.join("\n")
                color: Tokens.text
                font.family: "monospace"
                font.pixelSize: 12
            }
            CopyButton { content: MpvFacts.installCommands.join("\n") }
        }
    }

    SettingsCard {
        SettingRow {
            label: qsTrId("settingsBugReport")
            CopyButton {
                objectName: "copyDetails"
                label: qsTrId("settingsCopyDetails")
                content: block.details()
            }
        }
        SettingRow {
            visible: Core.onThisMachine && coreStatus.logPath !== ""
            label: qsTrId("settingsCoreLog")
            hint: coreStatus.logPath
            RowButton {
                text: qsTrId("commonOpen")
                onClicked: Qt.openUrlExternally("file://" + coreStatus.logPath.replace(/[\\/][^\\/]*$/, ""))
            }
        }
        SettingRow {
            label: qsTrId("settingsResetSettings")
            RowButton {
                objectName: "reset"
                text: qsTrId("settingsResetAction")
                onClicked: confirmReset.open()
            }
            Confirm {
                id: confirmReset
                objectName: "confirmReset"
                message: qsTrId("settingsResetConfirm")
                action: qsTrId("commonReset")
                onAccepted: {
                    block.settings.changedIn = block.section
                    LocalSettings.resetChoices()
                    Preferences.reset()
                }
            }
        }
        ErrorRow { message: block.settings.errorIn(block.section) }
    }

    component Value: Text {
        color: Tokens.dim
        font.family: Tokens.fontSans
        font.pixelSize: 13
        font.weight: Font.Medium
    }

    // A codec this machine has no decoder for is struck through.
    component Codecs: Row {
        id: codecs
        property var codecs: []
        spacing: 14
        Repeater {
            model: codecs.codecs
            delegate: Text {
                required property string modelData
                readonly property bool missing: MpvFacts.has(modelData) === 0
                text: modelData
                color: missing ? Tokens.warn : Tokens.text
                font.family: "monospace"
                font.pixelSize: 13
                font.strikeout: missing
            }
        }
    }
}
