pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Lumeo

// Search, a title, its copies: just enough to get a download playing.
ShellPage {
    id: root

    property var films: []
    property var series: []
    readonly property var results: films.concat(series)
    // The kinds still being asked for the word in the field.
    property int asking: 0
    property var title: null
    property var copies: []
    // Room left for the bar over the page.
    property real topPadding: 0

    Connections {
        target: Prototype
        function onSearched(query, kind, items) {
            if (query !== field.text)
                return
            if (kind === "movie") root.films = items
            else root.series = items
            root.asking = Math.max(0, root.asking - 1)
        }
        function onSourcesListed(sources) { root.copies = sources }
    }

    ColumnLayout {
        anchors { fill: parent; margins: 24; topMargin: 24 + root.topPadding }
        spacing: 16

        TextField {
            id: field
            Layout.preferredWidth: 480
            focus: true
            placeholderText: "Search"
            onTextChanged: wait.restart()

            // One search per word typed, not one per letter.
            Timer {
                id: wait
                interval: 300
                onTriggered: {
                    if (field.text.length < 2)
                        return
                    root.films = []
                    root.series = []
                    root.asking = 2
                    Prototype.search(field.text)
                }
            }
        }

        Label {
            text: root.asking > 0 ? "Searching…" : Prototype.status
            color: "#c3cad8"
            visible: text !== ""
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 24

            ListView {
                Layout.preferredWidth: 480
                Layout.fillHeight: true
                clip: true
                model: root.results
                delegate: ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    text: modelData.title + "  " + (modelData.year || "") + "  · " + modelData.kind
                    highlighted: root.title !== null && root.title.id === modelData.id
                    onClicked: {
                        root.title = modelData
                        root.copies = []
                        Prototype.sources(modelData.id, season.value, episode.value)
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.title !== null

                RowLayout {
                    visible: root.title !== null && root.title.kind === "series"
                    Label { text: "Season"; color: "#c3cad8" }
                    SpinBox { id: season; from: 1; to: 99; value: 1; focusPolicy: Qt.ClickFocus }
                    Label { text: "Episode"; color: "#c3cad8" }
                    SpinBox { id: episode; from: 1; to: 999; value: 1; focusPolicy: Qt.ClickFocus }
                    Button {
                        text: "Copies"
                        onClicked: Prototype.sources(root.title.id, season.value, episode.value)
                    }
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.copies
                    delegate: ItemDelegate {
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        text: [modelData.resolution, modelData.size, modelData.seeders + " seeders",
                               modelData.name].join("  ·  ")
                        onClicked: {
                            const series = root.title.kind === "series"
                            Prototype.play(root.title.id, index, series ? season.value : 0,
                                      series ? episode.value : 0)
                        }
                    }
                }
            }
        }
    }
}
