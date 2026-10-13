import QtQuick
import QtQuick.Controls.Basic
import Relay

// Labelled text field with an animated focus ring and optional leading icon.
Column {
    id: root
    property alias text: input.text
    property alias placeholder: input.placeholderText
    property alias input: input
    property string label
    property string iconName
    property bool password: false
    property bool error: false
    property bool mono: false
    signal accepted()

    spacing: 6
    function focusInput() { input.forceActiveFocus(); input.selectAll() }

    Text {
        visible: root.label !== ""
        text: root.label
        color: input.activeFocus ? Theme.text : Theme.textDim
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSm
        font.weight: Font.Medium
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }

    TextField {
        id: input
        width: root.width
        height: 38
        leftPadding: root.iconName ? 36 : 12
        rightPadding: root.password ? 38 : 12
        color: Theme.text
        placeholderTextColor: Theme.textFaint
        selectionColor: Theme.accentSoft
        selectedTextColor: Theme.text
        font.family: root.mono ? Theme.monoFamily : Theme.fontFamily
        font.pixelSize: Theme.fontMd
        echoMode: root.password && !reveal.checked ? TextInput.Password : TextInput.Normal
        onAccepted: root.accepted()

        background: Rectangle {
            radius: Theme.radius
            color: input.activeFocus ? Theme.surface : Theme.surface2
            border.width: 1
            border.color: root.error ? Theme.danger
                        : input.activeFocus ? Theme.accent
                        : input.hovered ? Theme.borderStrong : Theme.border
            Behavior on color { ColorAnimation { duration: Theme.fast } }
            Behavior on border.color { ColorAnimation { duration: Theme.fast } }

            // Focus halo grows out from the border.
            Rectangle {
                anchors.fill: parent
                anchors.margins: input.activeFocus ? -3 : 0
                radius: parent.radius + (input.activeFocus ? 3 : 0)
                color: "transparent"
                border.width: 3
                border.color: root.error ? Theme.dangerSoft : Theme.accentSoft
                opacity: input.activeFocus ? 1 : 0
                Behavior on anchors.margins { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                Behavior on opacity { NumberAnimation { duration: Theme.normal } }
            }
        }

        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: 15
            color: input.activeFocus ? Theme.accent : Theme.textFaint
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }

        AbstractButton {
            id: reveal
            visible: root.password
            checkable: true
            focusPolicy: Qt.NoFocus
            hoverEnabled: true
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 28; height: 28
            contentItem: Text {
                text: reveal.checked ? "Hide" : "Show"
                color: reveal.hovered ? Theme.text : Theme.textFaint
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
