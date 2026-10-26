import QtQuick
import QtQuick.Controls
import Lumeo

// Asks before something that cannot be taken back.
Dialog {
    id: dialog

    property string message
    property string action

    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    width: 400
    padding: 24

    background: Rectangle {
        color: Tokens.floating
        radius: Tokens.radiusFloating
        border.color: Tokens.rim
    }

    Text {
        width: dialog.availableWidth
        text: dialog.message
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: 15
        wrapMode: Text.Wrap
    }

    footer: DialogButtonBox {
        padding: 16
        background: null
        RowButton {
            text: qsTrId("commonCancel")
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        RowButton {
            objectName: "confirm"
            text: dialog.action
            palette.buttonText: Tokens.down
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }
}
