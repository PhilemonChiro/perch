import QtQuick
import QtQuick.Effects
import Relay

// Elevated surface with soft shadow.
Item {
    id: root
    default property alias content: inner.data
    property int padding: 24
    property real elevation: 1
    property color color: Theme.surface
    property int radius: Theme.radiusLg
    implicitWidth: inner.childrenRect.width + padding * 2
    implicitHeight: inner.childrenRect.height + padding * 2

    RectangularShadow {
        anchors.fill: bg
        radius: bg.radius
        blur: 28 * root.elevation
        offset.y: 10 * root.elevation
        spread: 0
        color: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.12)
    }
    Rectangle {
        id: bg
        anchors.fill: parent
        radius: root.radius
        color: root.color
        border.color: Theme.border
    }
    Item {
        id: inner
        anchors.fill: parent
        anchors.margins: root.padding
    }
}
