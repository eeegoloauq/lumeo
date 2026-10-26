pragma Singleton
import QtQuick
import Lumeo

// What the tokens do not say: the viewer's accent, and how long things take.
// Colours, radii, fonts and sizes are Tokens, from design/tokens.json.
QtObject {
    // Exactly one accent, white unless the viewer picks another, spent on
    // what will play and how much of it is here (decisions/interface.md).
    readonly property var accents: ({
        white: Tokens.accentWhite,
        amber: Tokens.accentAmber,
        red: Tokens.accentRed,
        violet: Tokens.accentViolet,
        blue: Tokens.accentBlue,
        teal: Tokens.accentTeal,
    })
    readonly property color accent: accents[Preferences.current.accent] ?? Tokens.accentWhite

    // A panel arriving or leaving.
    readonly property int panel: 250
    // The bar's ground fading in as the page moves under it.
    readonly property int wash: 180

    // A banner's height in whole device pixels: one inside a pixel
    // antialiases that row and the scrim's, and the picture shows through as
    // a line where the banner ends.
    function whole(value, ratio) {
        return Math.ceil(value * ratio - 1e-6) / ratio
    }
}
