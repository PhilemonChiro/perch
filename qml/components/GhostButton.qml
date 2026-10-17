import QtQuick
import QtQuick.Controls.Basic
import Relay

Button {
    id: root
    property string iconName
    implicitHeight: 30
    leftPadding: 14
    rightPadding: 14
    hoverEnabled: true

    scale: pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutBack; easing.overshoot: 2.5 } }

    background: Rectangle {
        radius: Theme.radius
        color: root.hovered ? Theme.surface3 : Theme.surface2
        border.color: root.hovered ? Theme.borderStrong : Theme.border
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        Behavior on border.color { ColorAnimation { duration: Theme.fast } }
    }
    contentItem: Row {
        spacing: 8
        anchors.centerIn: parent
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.iconName !== ""
            name: root.iconName
            size: 14
            color: Theme.text
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
        }
    }
}
