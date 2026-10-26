import QtQuick
import Lumeo
import "format.js" as Format

// The artwork at the head of a page, under the scrim that turns a frame we
// do not control into the page. Decoded at the screen's width: the window
// can grow to it, not past it.
Item {
    property string url

    Rectangle {
        anchors.fill: parent
        color: Tokens.surface
        visible: art.status !== Image.Ready
    }
    Image {
        id: art
        anchors.fill: parent
        source: Format.art(parent.url)
        sourceSize.width: Screen.width
        fillMode: Image.PreserveAspectCrop
        verticalAlignment: Image.AlignTop
    }
    ShaderEffect {
        anchors.fill: parent
        property color ground: Tokens.page
        fragmentShader: "qrc:/qt/qml/Lumeo/shaders/scrim.frag.qsb"
    }
}
