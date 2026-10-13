import QtQuick
import QtQuick.Layouts
import Relay

// Stack of transient notifications in the bottom-right corner.
Item {
    id: root
    width: 340
    height: col.height

    function show(message, kind) {
        model.append({ message: message, kind: kind || "info", key: Date.now() + Math.random() })
    }

    ListModel { id: model }

    Column {
        id: col
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 8
        move: Transition { NumberAnimation { properties: "y"; duration: Theme.normal; easing.type: Theme.easing } }

        Repeater {
            model: model
            delegate: Rectangle {
                id: toast
                required property int index
                required property string message
                required property string kind
                width: Math.max(220, Math.min(340, label.implicitWidth + 56))
                height: 44
                radius: Theme.radius
                color: Theme.surface3
                border.color: Theme.borderStrong
                anchors.right: parent ? parent.right : undefined
                opacity: 0
                transform: Translate { id: tr; y: 16 }

                Component.onCompleted: enter.start()
                ParallelAnimation {
                    id: enter
                    NumberAnimation { target: toast; property: "opacity"; to: 1; duration: Theme.normal }
                    NumberAnimation { target: tr; property: "y"; to: 0; duration: Theme.slow; easing.type: Easing.OutBack }
                }
                SequentialAnimation {
                    running: true
                    PauseAnimation { duration: 3200 }
                    NumberAnimation { target: toast; property: "opacity"; to: 0; duration: Theme.normal }
                    ScriptAction { script: model.remove(toast.index) }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 10
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: toast.kind === "error" ? Theme.danger
                             : toast.kind === "success" ? Theme.success : Theme.accent
                    }
                    Text {
                        id: label
                        Layout.fillWidth: true
                        text: toast.message
                        color: Theme.text
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontMd
                    }
                }
            }
        }
    }
}
