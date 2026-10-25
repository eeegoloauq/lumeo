pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Lumeo

// The chrome that stays: Back, the wordmark, search and the places. It has
// no fill or edge of its own: over artwork it is nothing, and once the page
// scrolls under it the ground arrives as a wash that fades downwards
// (decisions/interface.md).
Item {
    id: bar

    // The page on screen when it is one of the tabs; none on a page with a
    // way back, where the arrow says where it leads.
    property string lit
    property bool canGoBack
    property bool scrolled

    signal back()
    signal place(string name)
    signal search()

    implicitHeight: 68

    Rectangle {
        anchors.fill: parent
        opacity: bar.scrolled ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.wash } }
        // Opaque where the type sits, gone by the bottom edge.
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.alpha(Tokens.page, 0.95) }
            GradientStop { position: 0.72; color: Qt.alpha(Tokens.page, 0.9) }
            GradientStop { position: 1; color: Qt.alpha(Tokens.page, 0) }
        }
    }

    Item {
        id: controls
        anchors.fill: parent
        // Over a frame we do not control the type keeps a shadow under it,
        // or the bar disappears into a bright banner.
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#cc000000"
            shadowBlur: 0.5
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
        }

        // In the margin before the wordmark, which stays where it is on
        // every page; no fill at rest, or a circle would touch it.
        IconButton {
            objectName: "back"
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: bar.canGoBack
            glyph: 0xe092
            tip: qsTrId("playerBackEsc")
            onClicked: bar.back()
        }

        // Home from anywhere.
        Text {
            x: Tokens.gutter
            anchors.verticalCenter: parent.verticalCenter
            text: "LUMEO"
            color: Tokens.text
            font.family: Tokens.fontWordmark
            font.pixelSize: 15
            font.weight: Font.DemiBold
            font.letterSpacing: 4
            Accessible.role: Accessible.Link
            Accessible.name: qsTrId("homeTitle")

            TapHandler { onTapped: bar.place("home") }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }

        // Centred on the window, so nothing here moves when an end changes.
        Row {
            anchors.centerIn: parent
            spacing: 0

            IconButton {
                objectName: "search"
                glyph: 0xe567
                glyphSize: 19
                tone: Tokens.dim
                tip: qsTrId("searchShortcutTooltip")
                onClicked: bar.search()
            }
            Item { width: 6; height: 1 }
            Repeater {
                model: [
                    { name: "home", label: qsTrId("homeTitle") },
                    { name: "library", label: qsTrId("libraryTitle") },
                    { name: "settings", label: qsTrId("settingsTitle") },
                ]
                PillTab {
                    required property var modelData
                    objectName: "tab-" + modelData.name
                    text: modelData.label
                    lit: bar.lit === modelData.name
                    onClicked: bar.place(modelData.name)
                }
            }
        }
    }
}
