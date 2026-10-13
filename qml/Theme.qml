pragma Singleton
import QtQuick

QtObject {
    id: theme

    // Follows the OS appearance; can be forced via `mode`.
    property string mode: "system" // "system" | "dark" | "light"
    readonly property bool dark: mode === "dark"
        || (mode === "system" && Qt.styleHints.colorScheme !== Qt.ColorScheme.Light)

    // Surfaces
    readonly property color bg:        dark ? "#0A0B10" : "#F5F6FA"
    readonly property color sidebar:   dark ? "#0E1016" : "#EDEFF5"
    readonly property color surface:   dark ? "#13161E" : "#FFFFFF"
    readonly property color surface2:  dark ? "#1A1E28" : "#F0F2F7"
    readonly property color surface3:  dark ? "#222734" : "#E6E9F1"
    readonly property color border:    dark ? "#232835" : "#E0E3EB"
    readonly property color borderStrong: dark ? "#2E3445" : "#CDD2DE"
    readonly property color overlay:   dark ? Qt.rgba(0.02, 0.02, 0.05, 0.62) : Qt.rgba(0.09, 0.1, 0.16, 0.28)

    // Text
    readonly property color text:      dark ? "#ECEEF4" : "#12141B"
    readonly property color textDim:   dark ? "#8D94A7" : "#5C6377"
    readonly property color textFaint: dark ? "#5A6175" : "#9AA0B1"

    // Accent + semantic
    readonly property color accent:      dark ? "#8B7CFF" : "#5B4BF5"
    readonly property color accentHover: dark ? "#9D90FF" : "#4C3BEA"
    readonly property color accentSoft:  Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.16 : 0.11)
    readonly property color accent2:     "#22D3EE"
    readonly property color success:     "#34D399"
    readonly property color warning:     "#FBBF24"
    readonly property color danger:      "#F87171"
    readonly property color dangerSoft:  Qt.rgba(0.97, 0.44, 0.44, 0.14)
    readonly property color accentInk:    "#FFFFFF"

    // Shape
    readonly property int radiusSm: 6
    readonly property int radius: 10
    readonly property int radiusLg: 14
    readonly property int radiusXl: 20

    // Type
    readonly property string fontFamily: Qt.platform.os === "osx" ? Qt.application.font.family
        : Qt.platform.os === "windows" ? "Segoe UI Variable Text" : "Inter"
    readonly property string monoFamily: Qt.platform.os === "osx" ? "SF Mono"
        : Qt.platform.os === "windows" ? "Cascadia Mono" : "JetBrains Mono"
    readonly property int fontXs: 11
    readonly property int fontSm: 12
    readonly property int fontMd: 13
    readonly property int fontLg: 15
    readonly property int fontXl: 20
    readonly property int fontHero: 30

    // Motion: short and springy for direct feedback, longer for layout.
    readonly property int fast: 120
    readonly property int normal: 200
    readonly property int slow: 320
    readonly property int easing: Easing.OutCubic
    readonly property int easingEmph: Easing.OutBack

    // Shortcut sequences. While a session has focus, Cmd (macOS) or
    // Ctrl+Alt (elsewhere) combos stay with the app; everything else goes remote.
    readonly property bool mac: Qt.platform.os === "osx"
    readonly property string modLabel: mac ? "⌘" : "Ctrl+Alt+"
    function seq(key) { return mac ? "Ctrl+" + key : "Ctrl+Alt+" + key }

    function stateColor(state) {
        switch (state) {
        case 2: case 3: return warning   // connecting / verifying
        case 4: return success            // connected
        case 6: return danger             // failed
        default: return textFaint
        }
    }
}
