import QtQuick
import QtQuick.Controls.Basic
import Relay

// Pill switch whose knob springs across and stretches while pressed.
AbstractButton {
    id: root
    checkable: true
    hoverEnabled: true
    implicitWidth: track.width + (label.text ? label.implicitWidth + 10 : 0)
    implicitHeight: 22
    property alias label: label.text

    contentItem: Item {
        Rectangle {
            id: track
            width: 36; height: 20; radius: 10
            anchors.verticalCenter: parent.verticalCenter
            color: root.checked ? Theme.accent : (root.hovered ? Theme.surface3 : Theme.surface2)
            border.color: root.checked ? Theme.accent : Theme.borderStrong
            Behavior on color { ColorAnimation { duration: Theme.normal } }
            Rectangle {
                id: knob
                y: 2
                height: 16; radius: 8
                width: root.pressed ? 20 : 16
                x: root.checked ? track.width - width - 2 : 2
                color: "white"
                Behavior on x { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                Behavior on width { NumberAnimation { duration: Theme.fast } }
            }
        }
        Text {
            id: label
            anchors.left: track.right
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.textDim
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontMd
        }
    }
}
