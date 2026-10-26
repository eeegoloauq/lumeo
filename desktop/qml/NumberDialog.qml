import QtQuick
import QtQuick.Controls
import Lumeo

// Asks for a whole number between [min] and [max].
Dialog {
    id: dialog

    property string unit
    property int min
    property int max
    property int initial
    readonly property int number: Number(field.text)

    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    width: 340
    padding: 24
    topPadding: 8

    onAboutToShow: {
        field.text = String(Math.max(min, Math.min(initial, max)))
        field.selectAll()
        field.forceActiveFocus()
    }

    background: Rectangle {
        color: Tokens.floating
        radius: Tokens.radiusFloating
        border.color: Tokens.rim
    }
    header: Text {
        text: dialog.title
        padding: 24
        bottomPadding: 8
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textShelf
        font.weight: Font.DemiBold
        wrapMode: Text.Wrap
    }

    Column {
        spacing: 8

        Row {
            spacing: 10

            TextField {
                id: field
                objectName: "number"
                width: 160
                validator: IntValidator { bottom: dialog.min; top: dialog.max }
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 15
                background: Rectangle {
                    radius: Tokens.radiusControl
                    color: Tokens.surface
                    border.color: field.activeFocus ? Theme.accent : Tokens.line
                }
                onAccepted: if (acceptableInput) dialog.accept()
            }
            Text {
                anchors.verticalCenter: field.verticalCenter
                text: dialog.unit
                color: Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: 15
            }
        }
        Text {
            text: qsTrId("settingsNumberRange").arg(dialog.min.toLocaleString(Qt.locale(), "f", 0))
                                               .arg(dialog.max.toLocaleString(Qt.locale(), "f", 0))
                                               .arg(dialog.unit)
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: 12
        }
    }

    footer: DialogButtonBox {
        padding: 16
        background: null
        QuietButton {
            implicitHeight: 36
            text: qsTrId("commonCancel")
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        QuietButton {
            objectName: "set"
            implicitHeight: 36
            text: qsTrId("commonSet")
            enabled: field.acceptableInput
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }
}
