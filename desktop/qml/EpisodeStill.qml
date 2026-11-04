import QtQuick
import QtQuick.Effects
import Lumeo
import "format.js" as Format

// An episode's picture: its still, or with none its number on the ground,
// not the title's artwork, or every card reads as the same episode. What a
// card adds goes on top.
Item {
    id: still

    required property var episode
    // How the still is shown: "show", "blur" until watched, or "hide".
    property string stills: "show"
    property bool watched
    // How far into it the viewer is; 0 for none.
    property real bar
    // Not out, or out of reach: drawn faint.
    property bool faint
    // A frame taken from the file on disk, for an episode with no still.
    property string frame
    // The catalogue's still would not load: the frame stands in.
    property bool stillFailed: false

    Rectangle {
        anchors.fill: parent
        color: Tokens.surface
        opacity: still.faint ? 0.4 : 1

        Text {
            anchors.centerIn: parent
            text: still.episode.number ?? ""
            color: Qt.alpha(Tokens.text, 0.24)
            font.family: Tokens.fontSans
            font.pixelSize: Math.round(still.height / 5)
            font.weight: Font.DemiBold
        }
    }

    Image {
        anchors.fill: parent
        visible: status === Image.Ready && still.stills !== "hide"
        opacity: still.faint ? 0.4 : 1
        source: still.stills === "hide" ? ""
            : still.episode.thumbnail && !still.stillFailed
                ? (still.frame ? Format.still : Format.art)(still.episode.thumbnail)
            : still.frame
        onStatusChanged: if (status === Image.Error && still.episode.thumbnail) still.stillFailed = true
        sourceSize.width: Math.ceil(still.width * 1.1)
        fillMode: Image.PreserveAspectCrop
        // Only a real still is a spoiler; the number stays readable.
        layer.enabled: still.stills === "blur" && !still.watched
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 1
            blurMax: 32
        }
    }

    // How far the viewer is, the player's timeline in small; seen to the end
    // is the card's eye, not a full bar.
    WatchBar { share: still.bar }
}
