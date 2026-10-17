import QtQuick
import QtQuick.Controls.Basic
import Relay

// Round-cornered icon button with hover wash, press squash and tooltip.
AbstractButton {
    id: root
    property string iconName
    property int iconSize: 16
    property color tint: Theme.textDim
    property color hoverTint: Theme.text
    property string tip
    property bool danger: false

    implicitWidth: 30
    implicitHeight: 30
    hoverEnabled: true
    focusPolicy: Qt.NoFocus

    scale: pressed ? 0.88 : 1
    Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutBack; easing.overshoot: 3 } }

    // Hover is a clean chip; "active" (checked) keeps the chip and tints
    // the icon with the accent — no washed blue box.
    background: Rectangle {
        radius: Theme.radiusSm + 2
        color: root.danger && root.hovered ? Theme.dangerSoft
             : (root.checked || root.hovered) ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    contentItem: Item {
        Icon {
            anchors.centerIn: parent
            name: root.iconName
            size: root.iconSize
            color: root.danger && root.hovered ? Theme.danger
                 : root.checked ? Theme.accent
                 : root.hovered ? root.hoverTint : root.tint
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }
    }

    ToolTip {
        visible: root.tip !== "" && root.hovered && !root.pressed
        delay: 550
        text: root.tip
        y: root.height + 6
        padding: 6
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
        contentItem: Text { text: root.tip; color: Theme.text; font.pixelSize: Theme.fontSm; font.family: Theme.fontFamily }
        background: Rectangle { color: Theme.surface3; radius: Theme.radiusSm; border.color: Theme.borderStrong }
    }
}
