import QtQuick
import Lumeo

// A section of the settings page: its heading, then its cards of rows.
Column {
    id: block

    required property string title
    // Its name in SettingsPage.sections.
    required property string section
    default property alias content: parts.data

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
    Column {
        id: parts
        width: parent.width
        spacing: 14
    }
}
