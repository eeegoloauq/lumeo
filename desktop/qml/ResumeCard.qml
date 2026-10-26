import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import Lumeo
import "format.js" as Format

// A title being watched, in Continue watching: wide, over its backdrop, and
// named underneath, since a backdrop does not say what it is. Not the
// episode's still, which is blurred until watched and would make a row of
// blurs (decisions/interface.md).
AbstractButton {
    id: card

    required property var item
    property int season
    property int episode
    // The share of it seen, and the seconds left: 0 when not started.
    property real watched
    property real remaining
    // One of Downloads.marks, or undefined.
    property var mark

    readonly property bool lifted: hovered || visualFocus

    implicitWidth: 300
    implicitHeight: picture.height + 10 + caption.implicitHeight
    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    // Over its neighbours while lifted, or the next one covers its shadow.
    z: lifted ? 1 : 0
    Accessible.name: item.title

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: null
    contentItem: Item {
        Item {
            id: picture
            width: card.width
            height: Math.round(card.width * 9 / 16)
            scale: card.lifted ? 1.05 : 1
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
            layer.enabled: card.lifted
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: "#b3000000"
                shadowBlur: 0.7
                shadowVerticalOffset: 8
                shadowHorizontalOffset: 0
            }

            Rectangle { anchors.fill: parent; color: Tokens.raised }
            Image {
                anchors.fill: parent
                source: Format.art(card.item.background ?? "")
                // Decoded at the size it is drawn, with a little to spare for the lift.
                sourceSize.width: Math.ceil(card.width * 1.1)
                fillMode: Image.PreserveAspectCrop
            }
            DownloadMark {
                anchors { top: parent.top; right: parent.right; margins: 8 }
                visible: card.mark !== undefined
                mark: card.mark ?? {}
            }
            WatchBar { share: card.watched }
            // The keyboard's ring, in the accent, findable on any artwork.
            Rectangle {
                anchors.fill: parent
                visible: card.visualFocus
                color: "transparent"
                border.width: 2
                border.color: Theme.accent
            }
        }

        Column {
            id: caption
            anchors { top: picture.bottom; topMargin: 10 }
            width: card.width
            spacing: 3

            Text {
                width: parent.width
                text: card.item.title
                color: card.lifted ? Tokens.text : Tokens.dim
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textCard
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                objectName: "where"
                width: parent.width
                text: [card.episode > 0 ? qsTrId("downloadsSeasonEpisode").arg(card.season).arg(card.episode) : "",
                       card.remaining > 0 ? Words.timeLeft(card.remaining) : ""].filter(p => p).join(" · ")
                color: Tokens.muted
                font.family: Tokens.fontSans
                font.pixelSize: Tokens.textData
                elide: Text.ElideRight
            }
        }
    }
}
