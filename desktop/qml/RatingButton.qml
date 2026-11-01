pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Lumeo

// The viewer's own score, 1 to 10, and the way to give one. Ten numbers
// rather than five stars: a number says which one is pressed, where half a
// star has to be aimed at. The row fills to the number under the pointer or
// the keyboard, so the choice is seen before it is made.
AbstractButton {
    id: button

    // 0 when nothing was scored.
    property int score

    signal rated(int score)
    signal cleared()

    readonly property bool scored: score > 0

    implicitHeight: 36
    implicitWidth: scored ? row.implicitWidth + 24 : 36
    focusPolicy: Qt.TabFocus
    opacity: enabled ? 1 : 0.4
    Accessible.name: scored ? qsTrId("libraryRatingChange") : qsTrId("libraryRate")
    ToolTip {
        text: button.Accessible.name
        visible: button.hovered && !scores.opened
    }
    onClicked: scores.opened ? scores.close() : scores.open()
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: height / 2
        color: button.down ? Qt.lighter(Tokens.tint, 1.4) : button.hovered ? Qt.lighter(Tokens.tint, 1.2) : Tokens.tint
        border.width: button.visualFocus ? 2 : 0
        border.color: Theme.accent
    }
    contentItem: Item {
        Glyph { anchors.centerIn: parent; visible: !button.scored; glyph: "star_border"; size: 20 }
        Row {
            id: row
            anchors.centerIn: parent
            visible: button.scored
            spacing: 4
            Glyph { anchors.verticalCenter: parent.verticalCenter; glyph: "star"; size: 16 }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Number(button.score).toLocaleString(Qt.locale(), "f", 0)
                color: Tokens.text
                font.family: Tokens.fontSans
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
        }
    }

    RatingScale {
        id: scores
        // Above: the button sits at the banner's foot, often the window's.
        y: -height - 8
        score: button.score
        onRated: n => button.rated(n)
        onCleared: button.cleared()
    }
}
