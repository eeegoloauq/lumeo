pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

Dialog {
    id: dialog
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    width: Math.min(440, (parent?.width ?? 440) - 32)
    padding: 24
    title: qsTrId("connectionConnect")
    closePolicy: CoreConnection.busy ? Popup.NoAutoClose : Popup.CloseOnEscape

    component Entry: TextField {
        width: parent.width
        enabled: !CoreConnection.busy
        selectByMouse: true
        color: Tokens.text
        font.family: Tokens.fontSans
        font.pixelSize: 15
        background: Rectangle {
            radius: Tokens.radiusControl
            color: Tokens.surface
            border.color: parent.activeFocus ? Theme.accent : Tokens.line
        }
    }

    onAboutToShow: {
        address.text = CoreConnection.address
        code.clear()
        address.forceActiveFocus()
    }
    onClosed: code.clear()

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

    contentItem: Column {
        spacing: 12
        Entry {
            id: address
            objectName: "coreAddress"
            placeholderText: qsTrId("connectionAddress")
            Accessible.name: placeholderText
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
        }
        Entry {
            id: name
            objectName: "coreDeviceName"
            placeholderText: qsTrId("connectionDeviceName")
            Accessible.name: placeholderText
            maximumLength: 128
        }
        Entry {
            id: code
            objectName: "corePairCode"
            placeholderText: qsTrId("connectionPairCode")
            Accessible.name: placeholderText
            echoMode: TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
            onAccepted: if (connectButton.enabled) connectButton.clicked()
        }
        Text {
            width: parent.width
            text: qsTrId("connectionPairHint")
            color: Tokens.muted
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            wrapMode: Text.Wrap
        }
        Text {
            width: parent.width
            visible: CoreConnection.error !== ""
            text: CoreConnection.error
            color: Tokens.warn
            font.family: Tokens.fontSans
            font.pixelSize: Tokens.textData
            wrapMode: Text.Wrap
        }
    }

    Connections {
        target: CoreConnection
        function onChanged() {
            if (dialog.visible && !CoreConnection.busy && CoreConnection.error === "" && CoreConnection.remote && CoreConnection.restartNeeded)
                dialog.accept()
        }
    }

    footer: DialogButtonBox {
        padding: 16
        background: null
        QuietButton {
            text: qsTrId("commonCancel")
            enabled: !CoreConnection.busy
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        QuietButton {
            id: connectButton
            objectName: "pairCore"
            text: CoreConnection.busy ? qsTrId("connectionConnecting") : qsTrId("connectionConnect")
            enabled: !CoreConnection.busy && address.text.trim() !== "" && name.text.trim() !== "" && code.text.trim() !== ""
            onClicked: CoreConnection.pair(address.text, code.text, name.text)
        }
    }
}
