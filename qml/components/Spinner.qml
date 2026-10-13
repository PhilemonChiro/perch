import QtQuick
import QtQuick.Shapes
import Relay

// Indeterminate arc spinner whose sweep breathes while it rotates.
Item {
    id: root
    property int size: 20
    property real thickness: Math.max(1.5, size / 9)
    property color color: Theme.accent
    property bool running: true
    implicitWidth: size
    implicitHeight: size

    property real sweep: 90

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.18)
            strokeWidth: root.thickness
            fillColor: "transparent"
            PathAngleArc {
                centerX: root.size / 2; centerY: root.size / 2
                radiusX: (root.size - root.thickness) / 2; radiusY: radiusX
                startAngle: 0; sweepAngle: 360
            }
        }
    }
    Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.thickness
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.size / 2; centerY: root.size / 2
                radiusX: (root.size - root.thickness) / 2; radiusY: radiusX
                startAngle: -90; sweepAngle: root.sweep
            }
        }
        RotationAnimation on rotation {
            running: root.running && root.visible
            from: 0; to: 360; duration: 900
            loops: Animation.Infinite
        }
    }
    SequentialAnimation on sweep {
        running: root.running && root.visible
        loops: Animation.Infinite
        NumberAnimation { to: 270; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 40; duration: 700; easing.type: Easing.InOutSine }
    }
}
