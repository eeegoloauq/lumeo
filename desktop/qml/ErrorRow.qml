import QtQuick
import QtQuick.Layouts
import Lumeo

// The core's refusal, said in the section where it happened.
SettingRow {
    id: row

    property string message

    visible: message !== ""
    label: qsTrId("commonWhatItSaid")

    Text {
        text: row.message
        color: Tokens.warn
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textData
        wrapMode: Text.Wrap
        Layout.maximumWidth: 480
    }
}
