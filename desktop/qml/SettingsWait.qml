import QtQuick
import Lumeo

// What a section of core preferences shows until the core has answered.
Item {
    property string error

    visible: Object.keys(Preferences.current).length === 0 && error === ""
    width: parent?.width ?? 0
    height: visible ? 56 : 0

    Loading {
        anchors.verticalCenter: parent.verticalCenter
        waiting: parent.visible
    }
}
