import QtQuick
import QtQuick.Controls
import Lumeo

SettingsBlock {
    id: block

    required property var settings

    title: qsTrId("settingsAudioSubtitles")
    section: "audioSubtitles"

    readonly property var current: Preferences.current
    readonly property bool known: current.subtitleMode !== undefined

    function set(key, value) {
        settings.set(section, key, value)
    }

    SettingsCard {
        SettingRow {
            visible: block.known
            label: qsTrId("settingsAudioLanguages")
            stacked: true

            LanguageList {
                objectName: "audioLanguages"
                chosen: block.current.audioLanguages ?? []
                empty: qsTrId("settingsFileLanguage")
                onEdited: codes => block.set("audioLanguages", codes)
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsSubtitleLanguages")
            stacked: true

            LanguageList {
                objectName: "subtitleLanguages"
                chosen: block.current.subtitleLanguages ?? []
                onEdited: codes => block.set("subtitleLanguages", codes)
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsSubtitleMode")

            Segments {
                objectName: "subtitleMode"
                choices: [
                    { value: "always", label: qsTrId("settingsAlways") },
                    { value: "foreign", label: qsTrId("settingsForeignAudio"), tip: qsTrId("settingsForeignAudioHint") },
                    { value: "manual", label: qsTrId("settingsManual") },
                ]
                selected: block.current.subtitleMode
                onPicked: value => block.set("subtitleMode", value)
            }
        }
        SettingsWait { error: block.settings.errorIn(block.section) }
        ErrorRow { message: block.settings.errorIn(block.section) }
    }

    Text {
        visible: block.known
        topPadding: 14
        text: qsTrId("settingsSubtitleStyle")
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: 15
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
    }

    SubtitleSample {
        visible: block.known
        preferences: block.current
    }

    SettingsCard {
        visible: block.known

        SettingRow {
            label: qsTrId("settingsSubtitleSize")

            Segments {
                objectName: "subtitleScale"
                choices: SubtitleStyle.scales.map((scale, i) => ({
                    value: scale,
                    label: [qsTrId("playerSmall"), qsTrId("playerNormal"),
                            qsTrId("playerLarge"), qsTrId("playerLarger")][i],
                }))
                selected: SubtitleStyle.scales.find(s => Math.abs(s - (block.current.subtitleScale ?? 1)) < 0.01)
                onPicked: value => block.set("subtitleScale", value)
            }
        }
        SettingRow {
            label: qsTrId("settingsSubtitleColour")

            ColourDots {
                objectName: "subtitleColor"
                colours: SubtitleStyle.colours.map(c => ({
                    name: c.name,
                    colour: c.colour,
                    tip: ({
                        white: qsTrId("settingsAccentWhite"),
                        yellow: qsTrId("settingsSubtitleYellow"),
                        cream: qsTrId("settingsSubtitleCream"),
                        cyan: qsTrId("settingsSubtitleCyan"),
                    })[c.name],
                }))
                selected: block.current.subtitleColor ?? "white"
                onPicked: name => block.set("subtitleColor", name)
            }
        }
        SettingRow {
            label: qsTrId("settingsSubtitleBackground")

            Segments {
                objectName: "subtitleBackground"
                choices: [
                    { value: "none", label: qsTrId("settingsOutline") },
                    { value: "shadow", label: qsTrId("settingsShadow") },
                    { value: "box", label: qsTrId("settingsBox") },
                ]
                selected: block.current.subtitleBackground
                onPicked: value => block.set("subtitleBackground", value)
            }
        }
        SettingRow {
            label: qsTrId("settingsSubtitleHeight")

            // Stepped as a lift: mpv's sub-pos is 100 at the bottom edge and
            // a lower number raises the line.
            PreferenceStepper {
                objectName: "subtitleHeight"
                stored: 100 - (block.current.subtitlePosition ?? 100)
                min: 0
                max: 30
                step: 5
                valueWidth: 120
                // Below the bottom only by mpv's keys.
                describe: lift => lift < 0 ? qsTrId("settingsBelowPicture")
                    : lift === 0 ? qsTrId("settingsBottom")
                    : qsTrId("settingsPercentUp").arg(lift)
                lessTip: qsTrId("settingsLower")
                moreTip: qsTrId("settingsHigher")
                onChosen: lift => block.set("subtitlePosition", 100 - lift)
            }
        }
        SettingRow {
            label: qsTrId("settingsKeepFileStyling")

            SettingSwitch {
                objectName: "subtitleKeepStyling"
                label: qsTrId("settingsKeepFileStyling")
                checked: block.current.subtitleKeepStyling ?? true
                onToggled: block.set("subtitleKeepStyling", checked)
            }
        }
    }
}
