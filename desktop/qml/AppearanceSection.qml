import QtQuick
import Lumeo

SettingsBlock {
    id: block

    // The settings page: where a change goes and what it said.
    required property var settings

    title: qsTrId("settingsAppearance")
    section: "appearance"

    readonly property var current: Preferences.current

    SettingsCard {
        SettingRow {
            visible: block.current.accent !== undefined
            label: qsTrId("settingsAccent")

            ColourDots {
                colours: [
                    { name: "white", colour: Tokens.accentWhite, tip: qsTrId("settingsAccentWhite") },
                    { name: "amber", colour: Tokens.accentAmber, tip: qsTrId("settingsAccentAmber") },
                    { name: "red", colour: Tokens.accentRed, tip: qsTrId("settingsAccentRed") },
                    { name: "violet", colour: Tokens.accentViolet, tip: qsTrId("settingsAccentViolet") },
                    { name: "blue", colour: Tokens.accentBlue, tip: qsTrId("settingsAccentBlue") },
                    { name: "teal", colour: Tokens.accentTeal, tip: qsTrId("settingsAccentTeal") },
                ]
                selected: block.current.accent ?? ""
                onPicked: name => block.settings.set(block.section, "accent", name)
            }
        }
        SettingRow {
            visible: block.current.episodeArtwork !== undefined
            label: qsTrId("settingsEpisodeStills")

            Segments {
                objectName: "episodeArtwork"
                choices: [
                    { value: "show", label: qsTrId("settingsShow") },
                    { value: "blur", label: qsTrId("settingsBlur") },
                    { value: "hide", label: qsTrId("settingsHide") },
                ]
                selected: block.current.episodeArtwork
                onPicked: value => block.settings.set(block.section, "episodeArtwork", value)
            }
        }
        SettingsWait { error: block.settings.errorIn(block.section) }
        ErrorRow { message: block.settings.errorIn(block.section) }
    }
}
