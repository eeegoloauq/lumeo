import QtQuick
import Lumeo

SettingsBlock {
    id: block

    required property var settings

    title: qsTrId("settingsPlayback")
    section: "playback"

    readonly property var current: Preferences.current
    readonly property bool known: current.seekStep !== undefined

    function set(key, value) {
        settings.set(section, key, value)
    }

    SettingsCard {
        SettingRow {
            visible: block.known
            label: qsTrId("settingsCopyToPlay")

            Segments {
                objectName: "askCopy"
                choices: [
                    { value: false, label: qsTrId("itemReleaseAutomatic") },
                    { value: true, label: qsTrId("settingsAskEveryTime") },
                ]
                selected: block.current.askCopy
                onPicked: value => block.set("askCopy", value)
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsShowNextEpisode")

            PreferenceStepper {
                objectName: "nextNotice"
                stored: block.current.nextNotice ?? 0
                min: 0
                max: 120
                step: 5
                describe: seconds => qsTrId("commonSeconds", seconds)
                lessTip: qsTrId("settingsEarlier")
                moreTip: qsTrId("settingsLater")
                onChosen: value => block.set("nextNotice", value)
            }
            Hint { text: qsTrId("settingsBeforeEnd") }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsPlayNextEpisode")

            PresetChoice {
                objectName: "nextCountdown"
                presets: [
                    { value: 0, label: qsTrId("settingsOnPress") },
                    { value: 5, label: qsTrId("settingsAfterFiveSeconds") },
                ]
                value: block.current.nextCountdown ?? 0
                describe: seconds => qsTrId("settingsAfterSeconds", seconds)
                question: qsTrId("settingsPlayNextEpisodeAfter")
                unit: qsTrId("commonSecondUnit")
                min: 1
                max: 60
                initial: value === 0 ? 10 : value
                onChosen: value => block.set("nextCountdown", value)
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsArrowSkip")

            PresetChoice {
                objectName: "seekStep"
                presets: [
                    { value: 5, label: qsTrId("settingsFiveSeconds") },
                    { value: 10, label: qsTrId("settingsTenSeconds") },
                ]
                value: block.current.seekStep ?? 5
                describe: seconds => qsTrId("commonSeconds", seconds)
                question: qsTrId("settingsArrowSkipQuestion")
                unit: qsTrId("commonSecondUnit")
                min: 1
                max: 60
                initial: value
                onChosen: value => block.set("seekStep", value)
            }
            Hint { text: qsTrId("settingsShiftSkip") }
        }
        // This machine's: whether it can afford a second decoder.
        SettingRow {
            label: qsTrId("settingsTimelinePreviews")
            hint: qsTrId("settingsTimelinePreviewsHint")

            SettingSwitch {
                objectName: "timelinePreviews"
                label: qsTrId("settingsTimelinePreviews")
                checked: LocalSettings.timelinePreviews
                onToggled: LocalSettings.timelinePreviews = checked
            }
        }
        SettingsWait { error: block.settings.errorIn(block.section) }
        ErrorRow { message: block.settings.errorIn(block.section) }
    }

    component Hint: Text {
        color: Tokens.muted
        font.family: Tokens.fontSans
        font.pixelSize: 12
    }
}
