import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// Search's field, which stands where the tabs do while search is the page.
// The titles answer as it is typed into; Enter opens the best match.
TextField {
    id: field

    required property Search search

    // Down: from the field to what the page shows under it.
    signal down()

    implicitHeight: 44
    leftPadding: 44
    rightPadding: clear.visible ? 44 : 16
    text: search.query
    onTextEdited: search.query = text
    placeholderText: qsTrId("searchHint")
    placeholderTextColor: Tokens.muted
    color: Tokens.text
    selectionColor: Tokens.tint
    selectedTextColor: Tokens.text
    font.family: Tokens.fontSans
    font.pixelSize: Tokens.textBody
    verticalAlignment: TextInput.AlignVCenter
    selectByMouse: true
    Accessible.name: placeholderText

    Keys.onDownPressed: down()
    Keys.onReturnPressed: search.submit()
    Keys.onEnterPressed: search.submit()

    background: Rectangle {
        radius: height / 2
        color: Tokens.raised
        border.width: 1
        border.color: field.activeFocus ? Tokens.tint : Tokens.rim
    }

    Glyph {
        x: 16
        anchors.verticalCenter: parent.verticalCenter
        glyph: "search"
        color: Tokens.muted
    }

    IconButton {
        id: clear
        objectName: "clear"
        anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
        visible: field.search.query !== ""
        glyph: "close"
        glyphSize: 15
        tone: Tokens.dim
        tip: qsTrId("commonClear")
        focusPolicy: Qt.NoFocus
        onClicked: {
            field.search.query = ""
            field.forceActiveFocus()
        }
    }
}
