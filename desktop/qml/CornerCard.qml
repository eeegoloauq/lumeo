import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Lumeo

// A notice over the page's corner until it is closed: a title, a close
// button, what it has to say, and its buttons.
Pane {
    id: card

    required property string title
    default property alias content: body.data
    property alias buttons: buttons.data
    signal closed()

    implicitWidth: 360
    padding: 20
    background: Rectangle {
        radius: Tokens.radiusFloating
        color: Tokens.raised
        border.color: "#1affffff"
    }

    contentItem: ColumnLayout {
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: card.title
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 15
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }
            IconButton {
                objectName: "closeCard"
                glyph: "close"
                tip: qsTrId("commonClose")
                onClicked: card.closed()
            }
        }
        ColumnLayout {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10
        }
        Flow {
            id: buttons
            Layout.fillWidth: true
            spacing: 12
        }
    }
}
