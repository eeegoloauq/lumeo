import QtQuick
import Lumeo

// Copies, and says so for a moment: a button that looks the same afterwards
// gets pressed twice.
RowButton {
    id: button

    // What goes to the clipboard.
    required property string content
    property string label: qsTrId("commonCopy")

    contentItem: Text {
        text: said.running ? qsTrId("commonCopied") : button.label
        color: Tokens.text
        font: button.font
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    onClicked: {
        Desktop.copy(button.content)
        said.restart()
    }

    Timer { id: said; interval: 2000 }
}
