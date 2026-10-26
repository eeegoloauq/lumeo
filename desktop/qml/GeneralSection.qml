import QtQuick
import QtQuick.Controls
import Lumeo

SettingsBlock {
    title: qsTrId("settingsGeneral")
    section: "general"

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
}
