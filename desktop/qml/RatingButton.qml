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

    Popup {
        id: scores
        objectName: "ratingScale"
        // Above: the button sits at the banner's foot, often the window's.
        y: -height - 8
        margins: Theme.edge
        padding: 14
        // The number under the pointer or the keyboard, which the row fills to.
        property int lit
        readonly property int filled: lit > 0 ? lit : button.score

        function pick(n) {
            close()
            if (n !== button.score)
                button.rated(n)
        }

        // The keyboard opens on the score there is, or on the middle of the
        // scale, so the arrows have somewhere to start from.
        onOpened: {
            lit = 0
            numbers.itemAt((button.score > 0 ? button.score : 5) - 1).forceActiveFocus()
        }

        background: Rectangle {
            radius: Tokens.radiusFloating
            color: Qt.alpha(Tokens.floating, 0.97)
            border.color: Tokens.rim
        }
        contentItem: Column {
            spacing: 10

            Row {
                spacing: 12
                Text {
                    text: qsTrId("libraryYourRating")
                    color: Tokens.text
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textCard
                    font.weight: Font.DemiBold
                }
                Text {
                    text: scores.filled > 0 ? qsTrId("libraryRatingOfTen").arg(scores.filled) : ""
                    color: Tokens.muted
                    font.family: Tokens.fontSans
                    font.pixelSize: Tokens.textData
                    font.weight: Font.DemiBold
                }
            }
            Row {
                spacing: 4
                // Leaving the row puts it back; focus alone does not light
                // it, or the number the keyboard starts on reads as a score.
                HoverHandler { onHoveredChanged: if (!hovered) scores.lit = 0 }

                Repeater {
                    id: numbers
                    model: 10
                    AbstractButton {
                        id: number
                        required property int index
                        readonly property int value: index + 1
                        readonly property bool on: value <= scores.filled
                        objectName: "score-" + value
                        implicitWidth: 30
                        implicitHeight: 30
                        focusPolicy: Qt.TabFocus
                        onHoveredChanged: if (hovered) scores.lit = value
                        onClicked: scores.pick(value)
                        Keys.onLeftPressed: step(-1)
                        Keys.onRightPressed: step(1)
                        Keys.onReturnPressed: scores.pick(value)
                        Keys.onEnterPressed: scores.pick(value)
                        HoverHandler { cursorShape: Qt.PointingHandCursor }

                        function step(by) {
                            const to = Math.max(0, Math.min(9, index + by))
                            numbers.itemAt(to).forceActiveFocus(Qt.TabFocusReason)
                            scores.lit = to + 1
                        }

                        background: Rectangle {
                            radius: Tokens.radiusControl
                            color: number.on ? Tokens.text : Tokens.tint
                            border.width: number.visualFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        contentItem: Text {
                            text: number.value
                            color: number.on ? Tokens.page : Tokens.text
                            font.family: Tokens.fontSans
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
            AbstractButton {
                id: clear
                objectName: "clearScore"
                visible: button.scored
                implicitHeight: 30
                implicitWidth: clearLabel.implicitWidth + 16
                focusPolicy: Qt.TabFocus
                onClicked: {
                    scores.close()
                    button.cleared()
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                background: Rectangle {
                    radius: Tokens.radiusControl
                    color: clear.hovered ? Tokens.hover : "transparent"
                    border.width: clear.visualFocus ? 2 : 0
                    border.color: Theme.accent
                }
                contentItem: Text {
                    id: clearLabel
                    text: qsTrId("libraryRemoveRating")
                    color: Tokens.dim
                    font.family: Tokens.fontSans
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
