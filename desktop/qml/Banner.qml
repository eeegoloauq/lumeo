import QtQuick
import Lumeo
import "format.js" as Format

// The artwork at the head of a page, under the scrim that turns a frame we
// do not control into the page. Decoded at the screen's width: the window
// can grow to it, not past it.
Item {
    id: root

    property string url
    // Over the artwork and under the scrim: a picture moving in its place.
    default property alias content: slot.data

    Rectangle {
        anchors.fill: parent
        color: Tokens.surface
        visible: art.status !== Image.Ready
    }
    Image {
        id: art
        anchors.fill: parent
        source: Format.art(root.url)
        sourceSize.width: Screen.width
        fillMode: Image.PreserveAspectCrop
        verticalAlignment: Image.AlignTop
    }
    Item {
        id: slot
        anchors.fill: parent
    }
    ShaderEffect {
        anchors.fill: parent
        property color ground: Tokens.page
        fragmentShader: "qrc:/qt/qml/Lumeo/shaders/scrim.frag.qsb"
    }
}
