import QtQuick
import Lumeo

// Rows of a section on a card of their own, so they read as one thing.
Rectangle {
    default property alias rows: list.data

    width: parent?.width ?? 0
    // Not hidden when empty: a hidden card hides its rows, and they could
    // never give it a height to come back with.
    height: list.height
    radius: Tokens.radiusFloating
    color: Tokens.surface
    border.color: Tokens.rim
    border.width: height > 0 ? 1 : 0

    Column {
        id: list
        x: 20
        width: parent.width - 40
    }
}
