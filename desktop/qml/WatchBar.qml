import QtQuick
import Lumeo

// How much was watched, along a picture's foot: the player's timeline in
// small, white whatever the accent.
Rectangle {
    id: bar

    // The share watched; nothing is drawn at 0.
    property real share

    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 3
    visible: share > 0
    color: Tokens.watchTrack

    Rectangle {
        width: parent.width * Math.min(1, bar.share)
        height: parent.height
        color: Tokens.text
    }
}
