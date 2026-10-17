pragma Singleton
import QtQuick
import QtCore

// Relay "Calm studio": cool-neutral graphite surfaces, a single calm azure accent
// for brand and primary action, green reserved for live connection status.
QtObject {
    id: theme

    // Follows the OS appearance; can be forced via `mode`. Persisted across runs.
    property string mode: "system" // "system" | "dark" | "light"
    property Settings _settings: Settings {
        category: "appearance"
        property alias mode: theme.mode
    }
    readonly property bool dark: mode === "dark"
        || (mode === "system" && Qt.styleHints.colorScheme !== Qt.ColorScheme.Light)

    // Surfaces — elevation, not decoration. In light mode a deeper warm canvas
    // gives the white surfaces something to sit against, so it isn't washed out.
    readonly property color bg:        dark ? "#131417" : "#EAE9E3"
    readonly property color sidebar:   dark ? "#0F1013" : "#E3E2DB"
    readonly property color surface:   dark ? "#1A1C20" : "#FDFDFC"
    readonly property color surface2:  dark ? "#22242A" : "#ECEBE4"
    readonly property color surface3:  dark ? "#2B2E35" : "#DEDCD0"
    readonly property color border:    dark ? "#24262B" : "#CBC9BC"
    readonly property color borderStrong: dark ? "#343842" : "#AFAD9E"
    readonly property color overlay:   dark ? Qt.rgba(0.02, 0.02, 0.04, 0.66) : Qt.rgba(0.12, 0.12, 0.14, 0.34)
    // Row / menu-item hover: a clean elevation above the local surface. In light
    // this is white, not the muddy grey that surface2/3 read as on the sidebar
    // and popups; in dark it's a subtle lift.
    readonly property color hover:     dark ? "#2B2E35" : "#FFFFFF"

    // Text
    readonly property color text:      dark ? "#ECEDEF" : "#1C1D20"
    readonly property color textDim:   dark ? "#969AA3" : "#4E515A"
    readonly property color textFaint: dark ? "#5C606A" : "#6E6D62"

    // Accent — one calm azure, spent sparingly.
    readonly property color accent:      dark ? "#6E93FF" : "#3A63E0"
    readonly property color accentHover: dark ? "#88A6FF" : "#2E52C8"
    readonly property color accentSoft:  Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.15 : 0.10)
    // Fainter accent wash — for transient row hover in the results grid.
    readonly property color accentFaint: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.10 : 0.07)
    readonly property color accent2:     dark ? "#7FE3C6" : "#2FA98A"  // paired tone for the brand mark
    readonly property color accentInk:   "#FFFFFF"

    // Semantic — green means connected; it is not used decoratively.
    readonly property color success:     dark ? "#46C78E" : "#1F9D6B"
    readonly property color warning:     dark ? "#E7B64B" : "#C2881C"
    readonly property color danger:      dark ? "#F1766B" : "#D9564A"
    readonly property color dangerSoft:  Qt.rgba(danger.r, danger.g, danger.b, dark ? 0.16 : 0.12)

    // Elevation
    readonly property color shadow:      Qt.rgba(0, 0, 0, dark ? 0.52 : 0.12)

    // Shape — soft, with hierarchy.
    readonly property int radiusSm: 7
    readonly property int radius: 11
    readonly property int radiusLg: 16
    readonly property int radiusXl: 22

    // Type — the native UI font on each OS (Segoe UI on Windows, SF Pro on macOS,
    // the configured sans on Linux), and a monospace that ships by default on each.
    readonly property string fontFamily: Qt.application.font.family
    readonly property string monoFamily: Qt.platform.os === "osx" ? "Menlo"
        : Qt.platform.os === "windows" ? "Consolas" : "DejaVu Sans Mono"
    readonly property int fontXs: 11
    readonly property int fontSm: 12
    readonly property int fontMd: 13
    readonly property int fontLg: 15
    readonly property int fontXl: 21
    readonly property int fontHero: 34

    // Motion — unhurried and smooth; action-driven, not decorative.
    readonly property int fast: 130
    readonly property int normal: 220
    readonly property int slow: 380
    readonly property int easing: Easing.OutCubic
    readonly property int easingEmph: Easing.OutQuint

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

    // SQL syntax highlighting — calm, distinct hues that sit on the editor surface.
    readonly property color sqlKeyword:    dark ? "#6E93FF" : "#3A63E0"  // azure, matches accent
    readonly property color sqlFunction:   dark ? "#7FE3C6" : "#1F9D6B"  // teal
    readonly property color sqlString:     dark ? "#E0A26B" : "#B4692A"  // warm amber
    readonly property color sqlNumber:     dark ? "#C99BFF" : "#8A4FD6"  // violet
    readonly property color sqlComment:    dark ? "#5C606A" : "#9A998E"  // muted
    readonly property color sqlIdentifier: dark ? "#9FB4D8" : "#4A5A78"  // steel (for [brackets])
    readonly property color sqlOperator:   dark ? "#8A8E97" : "#6C6F76"

    // Colour tag per connection kind: RDP desktops vs SQL databases.
    readonly property color rdpTag: accent               // blue
    readonly property color sqlTag: dark ? "#C99BFF" : "#8A4FD6"  // violet
    function kindColor(kind) { return kind === "sql" ? sqlTag : rdpTag }

    // Shared lifecycle phase colour (0 idle,1 connecting,2 live,3 busy,4 ended,5 failed).
    function phaseColor(phase) {
        switch (phase) {
        case 1: return warning   // connecting
        case 2: return success   // live
        case 3: return accent    // busy (running a query)
        case 5: return danger    // failed
        case 4:                  // ended / paused
        default: return textFaint
        }
    }
}
