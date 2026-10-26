import QtQuick
import Lumeo

// An empty screen is an invitation to act: what is missing or failed, why
// when the core said, and the one thing that can help.
Column {
    id: trouble

    property string title
    property string hint
    property string detail
    // The way out, such as Try again; none when empty.
    property string action
    signal acted()

    width: Math.min(460, parent.width - 2 * Tokens.gutter)
    spacing: 12

    Text {
        width: parent.width
        text: trouble.title
        color: "white"
        font.family: Tokens.fontSans
        font.pixelSize: 26
        font.weight: Font.Bold
        wrapMode: Text.Wrap
    }
    Text {
        width: parent.width
        text: trouble.hint
        color: Tokens.muted
        font.family: Tokens.fontSans
        font.pixelSize: 15
        lineHeightMode: Text.FixedHeight
        lineHeight: 15 * 1.5
        wrapMode: Text.Wrap
    }
    Text {
        width: parent.width
        visible: text !== ""
        text: trouble.detail
        color: Tokens.muted
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textData
        wrapMode: Text.Wrap
    }
    Item { width: 1; height: 10; visible: trouble.action !== "" }
    QuietButton {
        objectName: "action"
        visible: trouble.action !== ""
        text: trouble.action
        onClicked: trouble.acted()
    }
}
