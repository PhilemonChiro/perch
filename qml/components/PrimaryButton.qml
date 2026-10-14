import QtQuick
import QtQuick.Controls.Basic
import Relay

// Accent button: gradient fill, glow on hover, squash on press, inline spinner when busy.
Button {
    id: root
    property bool busy: false
    property string iconName
    property bool destructive: false

    implicitHeight: 38
    leftPadding: 18
    rightPadding: 18
    hoverEnabled: true
    enabled: !busy

    scale: pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutBack; easing.overshoot: 2.5 } }

    readonly property color base: destructive ? Theme.danger : Theme.accent

    background: Rectangle {
        radius: Theme.radius
        opacity: root.enabled || root.busy ? 1 : 0.45
        gradient: Gradient {
            orientation: Gradient.Vertical
            // Dark: lift the top for a glossy accent. Light: keep it solid and
            // saturated (lightening it there reads pale and washes out white text).
            GradientStop { position: 0; color: Theme.dark ? Qt.lighter(root.base, root.hovered ? 1.18 : 1.08)
                                                          : (root.hovered ? Qt.lighter(root.base, 1.05) : root.base) }
            GradientStop { position: 1; color: Theme.dark ? (root.hovered ? Qt.lighter(root.base, 1.05) : root.base)
                                                          : Qt.darker(root.base, 1.1) }
        }
        // Soft glow that blooms on hover.
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -4
            radius: parent.radius + 4
            color: "transparent"
            border.width: 4
            border.color: Qt.rgba(root.base.r, root.base.g, root.base.b, root.hovered ? 0.22 : 0)
            Behavior on border.color { ColorAnimation { duration: Theme.normal } }
        }
        // Inner top highlight for depth.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
            height: 1
            radius: 1
            color: Qt.rgba(1, 1, 1, 0.22)
        }
    }

    contentItem: Row {
        spacing: 8
        anchors.centerIn: parent
        Spinner {
            anchors.verticalCenter: parent.verticalCenter
            size: 14
            color: Theme.accentInk
            visible: root.busy
            running: root.busy
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.iconName !== "" && !root.busy
            name: root.iconName
            size: 15
            color: Theme.accentInk
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: Theme.accentInk
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold
        }
    }
}
