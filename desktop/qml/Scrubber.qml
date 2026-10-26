pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Lumeo

// The seek bar: how much has played, how much of the file is on disk behind
// it, a gap where each chapter starts, and over the pointer the chapter and
// the time it would seek to (decisions/player.md).
Slider {
    id: bar

    required property real duration
    // Where the film is, in seconds.
    required property real time
    // How much of the file is on disk, 0 to 1.
    property real acquired: 0
    // mpv's chapter list: [{time, title}].
    property var chapters: []

    readonly property bool playable: duration > 0
    // Where the pointer is or the thumb is being dragged, 0 to 1; -1 when
    // neither.
    readonly property real pointed: pressed ? value
        : hover.hovered ? Math.max(0, Math.min(1, hover.point.position.x / width)) : -1

    // The chapter at [seconds], -1 before the first.
    function chapterAt(seconds) {
        let at = -1
        for (let i = 0; i < chapters.length; ++i)
            if (chapters[i].time <= seconds)
                at = i
        return at
    }

    function chapterLabel(index) {
        return chapters[index].title || qsTrId("playerChapter").arg(index + 1)
    }

    implicitHeight: 16
    padding: 0
    focusPolicy: Qt.NoFocus
    enabled: playable
    from: 0
    to: 1

    Binding on value {
        when: !bar.pressed
        value: bar.playable ? Math.min(1, bar.time / bar.duration) : 0
    }

    HoverHandler { id: hover }

    background: Item {
        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 3
            color: "#40ffffff"

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, bar.acquired))
                height: parent.height
                color: "#73ffffff"
            }

            Rectangle {
                width: parent.width * bar.visualPosition
                height: parent.height
                color: "white"
            }

            Repeater {
                model: bar.playable ? bar.chapters : []
                delegate: Rectangle {
                    required property var modelData
                    visible: modelData.time > 0 && modelData.time < bar.duration
                    x: track.width * modelData.time / bar.duration - 1
                    width: 2
                    height: track.height
                    color: "black"
                }
            }
        }
    }

    handle: Rectangle {
        x: bar.visualPosition * bar.width - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 12
        radius: 6
        color: "white"
        visible: bar.playable
    }

    // Centred over the pointer, and stopped at the ends of the bar.
    Column {
        id: preview

        readonly property real seconds: bar.pointed * bar.duration
        readonly property int chapter: bar.chapterAt(seconds)

        visible: bar.playable && bar.pointed >= 0
        x: Math.max(0, Math.min(bar.width - width, bar.pointed * bar.width - width / 2))
        anchors.bottom: parent.top
        anchors.bottomMargin: 6
        spacing: 4

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: preview.chapter >= 0
            text: visible ? bar.chapterLabel(preview.chapter) : ""
            width: Math.min(implicitWidth, 320)
            elide: Text.ElideRight
            color: "white"
            font.family: Tokens.fontSans
            font.pixelSize: 13
            font.weight: Font.DemiBold
            style: Text.Outline
            styleColor: "#66000000"
        }

        Rectangle {
            objectName: "pointedTime"
            anchors.horizontalCenter: parent.horizontalCenter
            width: time.implicitWidth + 16
            height: 22
            radius: 11
            color: "#b3000000"

            Text {
                id: time
                anchors.centerIn: parent
                text: Words.clock(preview.seconds)
                color: "white"
                font.family: Tokens.fontSans
                font.pixelSize: 13
                font.weight: Font.Medium
                font.features: { "tnum": 1 }
            }
        }
    }
}
