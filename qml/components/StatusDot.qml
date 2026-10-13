import QtQuick
import Relay

// Session state dot; emits a soft ripple while connecting.
Item {
    id: root
    property int state: 0
    property int size: 7
    readonly property bool busy: state === 2 || state === 3
    implicitWidth: size
    implicitHeight: size

    Rectangle {
        id: ripple
        anchors.centerIn: parent
        width: root.size; height: width; radius: width / 2
        color: "transparent"
        border.width: 1.5
        border.color: dot.color
        opacity: 0
        visible: root.busy
        ParallelAnimation {
            running: root.busy
            loops: Animation.Infinite
            NumberAnimation { target: ripple; property: "width"; from: root.size; to: root.size * 3; duration: 1100; easing.type: Easing.OutCubic }
            NumberAnimation { target: ripple; property: "opacity"; from: 0.8; to: 0; duration: 1100; easing.type: Easing.OutCubic }
        }
    }
    Rectangle {
        id: dot
        anchors.centerIn: parent
        width: root.size; height: width; radius: width / 2
        color: Theme.stateColor(root.state)
        Behavior on color { ColorAnimation { duration: Theme.slow } }
    }
    // A brief pop when the session comes up.
    onStateChanged: if (state === 4) pop.restart()
    SequentialAnimation {
        id: pop
        NumberAnimation { target: dot; property: "scale"; to: 1.7; duration: 140; easing.type: Easing.OutCubic }
        NumberAnimation { target: dot; property: "scale"; to: 1; duration: 260; easing.type: Easing.OutBack }
    }
}
