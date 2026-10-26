import QtQuick
import Lumeo

// A few presets and a Custom at the end that asks for a number. A value
// outside the presets lights Custom and says what it is; pressing it again
// asks again.
Segments {
    id: choice

    // [{value, label, tip}]
    required property var presets
    required property int value
    // How a custom value reads on its segment.
    required property var describe
    property alias question: ask.title
    property alias unit: ask.unit
    property alias min: ask.min
    property alias max: ask.max
    // What the question starts from.
    property alias initial: ask.initial

    signal chosen(int value)

    readonly property bool preset: presets.some(p => p.value === value)

    choices: presets.concat([{ value: -1, label: preset ? qsTrId("commonCustom") : describe(value) }])
    selected: preset ? value : -1
    onPicked: picked => {
        if (picked === -1)
            ask.open()
        else
            chosen(picked)
    }

    NumberDialog {
        id: ask
        onAccepted: choice.chosen(number)
    }
}
