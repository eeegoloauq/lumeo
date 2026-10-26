import QtQuick
import Lumeo

// A section of the settings page: its heading and its rows.
Column {
    id: block

    required property string title
    // Its name in SettingsPage.sections.
    required property string section
    default property alias rows: list.data

    // The air above a heading, which is also where a section scrolled to
    // puts it.
    readonly property real headingTop: 56

    width: parent?.width ?? 0
    topPadding: headingTop
    spacing: 14

    Text {
        text: block.title
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: 22
        font.weight: Font.DemiBold
        font.letterSpacing: -0.2
        Accessible.role: Accessible.Heading
    }
    // The rows on a card of their own, so a section reads as one thing.
    Rectangle {
        width: parent.width
        height: list.height
        visible: list.height > 0
        radius: Tokens.radiusFloating
        color: Tokens.surface
        border.color: Tokens.rim

        Column {
            id: list
            x: 20
            width: parent.width - 40
        }
    }
}
