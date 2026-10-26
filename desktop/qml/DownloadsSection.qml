pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import Lumeo
import "format.js" as Format

// Where downloads go, how long they stay, what the swarm may take, and what
// is on disk now.
SettingsBlock {
    id: block

    required property var settings

    title: qsTrId("settingsDownloads")
    section: "downloads"

    readonly property var current: Preferences.current
    readonly property bool known: current.keep !== undefined
    readonly property real gib: 1073741824
    readonly property real mib: 1048576
    readonly property string keep: current.keep === "watched" ? "watched"
        : current.keep !== "days" ? "forever"
        : current.keepDays === 30 ? "days30" : "custom"

    // The core frees what a new policy expires before it answers, so the
    // list read after it is the new one.
    function setPolicy(change) {
        settings.changedIn = section
        Preferences.patch(change)
        policyChange.pending = true
    }

    function set(key, value) {
        settings.set(section, key, value)
    }

    function rates(megabytes) {
        return megabytes.map(mb => ({
            value: mb,
            label: mb === 0 ? qsTrId("settingsNoLimit") : qsTrId("settingsMegabytesPerSecond").arg(mb),
        }))
    }

    function localPath(url) {
        const path = decodeURIComponent(url.toString().replace(/^file:\/\//, ""))
        return Qt.platform.os === "windows" ? path.replace(/^\//, "") : path
    }

    readonly property string screenshots: LocalSettings.screenshotsDir
        || StandardPaths.writableLocation(StandardPaths.PicturesLocation).toString()
               .replace(/^file:\/\//, "") + "/Lumeo"

    Storage { id: disk }
    CoreStatus { id: coreStatus }

    Connections {
        id: policyChange
        property bool pending
        target: Preferences
        function onChanged() {
            if (!policyChange.pending)
                return
            policyChange.pending = false
            Downloads.refresh()
            disk.load()
            coreStatus.load()
        }
    }

    SettingsCard {
        StorageBar {
            storage: disk
            limit: block.current.diskLimit ?? 0
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsDiskLimit")

            PresetChoice {
                objectName: "diskLimit"
                presets: [
                    { value: 50, label: qsTrId("settingsGigabytes", 50), tip: qsTrId("settingsDiskLimitTooltip") },
                    { value: 100, label: qsTrId("settingsGigabytes", 100), tip: qsTrId("settingsDiskLimitTooltip") },
                    { value: 0, label: qsTrId("settingsNoLimit") },
                ]
                value: Math.round((block.current.diskLimit ?? 0) / block.gib)
                describe: gb => qsTrId("settingsGigabytes", gb)
                question: qsTrId("settingsDiskLimit")
                unit: qsTrId("settingsGigabyteUnit")
                min: 1
                max: 100000
                initial: value === 0 ? 250 : value
                onChosen: gb => block.setPolicy({ diskLimit: gb * block.gib })
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsDeleteWatched")

            Segments {
                objectName: "keep"
                choices: [
                    { value: "watched", label: qsTrId("settingsRightAway") },
                    { value: "days30", label: qsTrId("settingsAfterThirtyDays") },
                    { value: "custom", label: block.keep === "custom"
                        ? qsTrId("settingsAfterDays", block.current.keepDays) : qsTrId("commonCustom") },
                    { value: "forever", label: qsTrId("settingsNever") },
                ]
                selected: block.keep
                onPicked: value => {
                    if (value === "custom")
                        days.open()
                    else if (value === "days30")
                        block.setPolicy({ keep: "days", keepDays: 30 })
                    else
                        block.setPolicy({ keep: value })
                }

                NumberDialog {
                    id: days
                    title: qsTrId("settingsDeleteWatchedAfter")
                    unit: qsTrId("settingsDayUnit")
                    min: 1
                    max: 365
                    initial: block.current.keepDays ?? 30
                    onAccepted: block.setPolicy({ keep: "days", keepDays: number })
                }
            }
        }
        SettingRow {
            visible: block.known
            label: qsTrId("settingsDownloadNextEpisode")

            SettingSwitch {
                objectName: "prefetch"
                label: qsTrId("settingsDownloadNextEpisode")
                checked: block.current.prefetch ?? true
                onToggled: block.setPolicy({ prefetch: checked })
            }
        }
        SettingsWait { error: block.settings.errorIn(block.section) }
        ErrorRow { message: block.settings.errorIn(block.section) }
    }

    SettingsCard {
        // The folder is on the core's machine: opened or changed only when
        // that is this one.
        SettingRow {
            label: qsTrId("settingsVideos")
            hint: coreStatus.downloadDir

            RowButton {
                visible: Core.onThisMachine && coreStatus.downloadDir !== ""
                text: qsTrId("commonOpen")
                onClicked: Qt.openUrlExternally("file://" + coreStatus.downloadDir)
            }
            RowButton {
                visible: Core.onThisMachine && block.known
                text: qsTrId("commonChange")
                onClicked: {
                    folders.purpose = "videos"
                    folders.title = qsTrId("settingsDownloadFolderQuestion")
                    folders.currentFolder = "file://" + coreStatus.downloadDir
                    folders.open()
                }
            }
            RowButton {
                visible: (block.current.downloadDir ?? "") !== ""
                text: qsTrId("settingsDefault")
                onClicked: block.setPolicy({ downloadDir: null })
            }
        }
        SettingRow {
            label: qsTrId("settingsScreenshots")
            hint: block.screenshots

            RowButton {
                text: qsTrId("commonOpen")
                onClicked: Qt.openUrlExternally("file://" + block.screenshots)
            }
            RowButton {
                text: qsTrId("commonChange")
                onClicked: {
                    folders.purpose = "screenshots"
                    folders.title = qsTrId("settingsScreenshotsFolderQuestion")
                    folders.currentFolder = "file://" + block.screenshots
                    folders.open()
                }
            }
            RowButton {
                visible: LocalSettings.screenshotsDir !== ""
                text: qsTrId("settingsDefault")
                onClicked: LocalSettings.screenshotsDir = ""
            }
        }
    }

    FolderDialog {
        id: folders
        property string purpose
        onAccepted: {
            const path = block.localPath(selectedFolder)
            if (purpose === "screenshots")
                LocalSettings.screenshotsDir = path
            else if (path !== coreStatus.downloadDir)
                block.setPolicy({ downloadDir: path })
        }
    }

    Subheading { visible: block.known; text: qsTrId("settingsNetwork") }

    SettingsCard {
        visible: block.known

        SettingRow {
            label: qsTrId("settingsUploadLimit")
            RateChoice { key: "uploadLimit"; presets: block.rates([0, 1, 5]) }
        }
        SettingRow {
            label: qsTrId("settingsDownloadLimit")
            RateChoice { key: "downloadLimit"; presets: block.rates([0, 5, 20]) }
        }
    }

    Item {
        width: parent.width
        height: 44

        Subheading {
            anchors.bottom: parent.bottom
            text: qsTrId("downloadsOnDisk") + (disk.used > 0 ? "  ·  " + Words.bytes(disk.used) : "")
        }
        RowButton {
            objectName: "deleteAll"
            anchors { right: parent.right; bottom: parent.bottom; bottomMargin: -6 }
            visible: disk.titles.length > 0
            enabled: disk.freeing === ""
            text: qsTrId("settingsDeleteAll")
            onClicked: confirmAll.open()
        }
        Confirm {
            id: confirmAll
            objectName: "confirmAll"
            message: qsTrId("settingsDeleteAllConfirm").arg(Words.bytes(disk.used))
            action: qsTrId("commonDelete")
            onAccepted: disk.freeAll()
        }
    }

    SettingsCard {
        objectName: "onDisk"

        ErrorRow { message: disk.error }
        Text {
            visible: disk.known && disk.titles.length === 0
            width: parent.width
            topPadding: 18
            bottomPadding: 18
            text: qsTrId("settingsNothingDownloaded")
            color: Tokens.dim
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
        }
        Repeater {
            model: disk.titles
            delegate: SettingRow {
                id: title
                required property var modelData
                readonly property bool active: modelData.downloads.some(d => d.state === "active")
                readonly property string detail: modelData.kind === "movie" ? qsTrId("commonFilm")
                    : qsTrId("settingsEpisodeCount", modelData.downloads.length)
                objectName: "title-" + modelData.key
                label: modelData.title
                hint: active ? qsTrId("settingsDetailDownloading").arg(detail) : detail

                Text {
                    text: Words.bytes(title.modelData.onDisk)
                    color: Tokens.dim
                    font.family: Tokens.fontSans
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
                RowButton {
                    objectName: "delete"
                    text: disk.freeing === title.modelData.key ? qsTrId("settingsDeleting") : qsTrId("commonDelete")
                    enabled: disk.freeing === ""
                    onClicked: disk.free(title.modelData.key)
                }
            }
        }
        SettingRow {
            visible: disk.cache > 0
            label: qsTrId("settingsCachedArtwork")
            hint: Words.bytes(disk.cache)

            RowButton {
                text: qsTrId("commonClear")
                enabled: disk.freeing === ""
                onClicked: disk.clearCache()
            }
        }
    }

    component Subheading: Text {
        topPadding: 14
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: 15
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
    }

    // A rate in MB/s among presets, 0 for none, or any other asked for.
    component RateChoice: PresetChoice {
        required property string key
        objectName: key
        value: Math.round((block.current[key] ?? 0) / block.mib)
        describe: mb => qsTrId("settingsMegabytesPerSecond").arg(mb)
        question: key === "uploadLimit" ? qsTrId("settingsUploadLimit") : qsTrId("settingsDownloadLimit")
        unit: qsTrId("settingsMegabytesPerSecondUnit")
        min: 1
        max: 1000
        initial: value === 0 ? 10 : value
        onChosen: mb => block.set(key, mb * block.mib)
    }
}
