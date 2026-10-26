import QtQuick
import QtQuick.Controls
import Lumeo

// A wait, shown only past one worth showing, or it blinks on every fast
// answer.
BusyIndicator {
    id: busy

    property bool waiting

    width: 32
    height: 32
    palette.dark: Theme.accent
    visible: waiting && !patience.running
    running: visible

    Timer {
        id: patience
        interval: 300
        running: busy.waiting
    }
}
