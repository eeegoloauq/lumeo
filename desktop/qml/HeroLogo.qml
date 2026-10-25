import QtQuick
import Lumeo
import "format.js" as Format

// The title card the provider drew, its ink repainted white when it would
// vanish on our ground. Until it comes the title is its text, in the logo's
// box so nothing below moves: after 400 ms, so a logo close at hand never
// flashes the text first, and for good when the logo fails. The logo fades
// in over it (decisions/interface.md).
Item {
    id: logo

    required property string url
    required property string title

    implicitWidth: 640
    implicitHeight: 132

    Timer {
        id: late
        interval: 400
        running: true
    }

    Text {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        opacity: image.status === Image.Error || (!late.running && image.status !== Image.Ready) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        text: logo.title
        color: "white"
        font.family: Tokens.fontSans
        font.pixelSize: Tokens.textHero
        font.weight: Font.Bold
        font.letterSpacing: -1.2
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.textHero * 1.05
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }

    Image {
        id: image
        anchors.fill: parent
        source: Format.logo(logo.url)
        sourceSize.height: logo.height
        fillMode: Image.PreserveAspectFit
        horizontalAlignment: Image.AlignLeft
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }
}
