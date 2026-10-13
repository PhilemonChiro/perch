import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

Rectangle {
    id: root
    implicitHeight: 46
    color: Theme.bg

    property int current: -1
    property bool sidebarOpen: true
    signal select(int index)
    signal closeTab(int index)
    signal showSidebar()
    signal newTab()

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 4

        IconButton {
            visible: !root.sidebarOpen
            iconName: "sidebar"
            tip: qsTr("Show sidebar  %1B").arg(Theme.modLabel)
            onClicked: root.showSidebar()
        }
        IconButton {
            iconName: "home"
            checkable: false
            checked: root.current < 0
            tip: qsTr("Home  %10").arg(Theme.modLabel)
            onClicked: root.select(-1)
        }
        Rectangle { width: 1; height: 18; color: Theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }

        ListView {
            id: tabs
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            orientation: ListView.Horizontal
            spacing: 4
            clip: true
            model: SessionManager
            currentIndex: root.current
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentWidth > width
            readonly property real tabWidth: count ? Math.max(130, Math.min(220, (width - spacing * (count - 1)) / count)) : 220

            // The active pill slides between tabs.
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 260
            highlightMoveVelocity: -1
            highlightResizeDuration: 260
            highlightResizeVelocity: -1
            highlight: Rectangle {
                radius: Theme.radius
                color: Theme.surface
                border.color: Theme.border
                opacity: root.current >= 0 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottomMargin: 3
                    width: 18; height: 2; radius: 1
                    color: Theme.accent
                }
            }

            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
                    NumberAnimation { property: "scale"; from: 0.85; to: 1; duration: Theme.slow; easing.type: Easing.OutBack }
                }
            }
            remove: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast }
                    NumberAnimation { property: "scale"; to: 0.85; duration: Theme.fast }
                }
            }
            displaced: Transition { NumberAnimation { properties: "x"; duration: Theme.normal; easing.type: Theme.easing } }

            delegate: AbstractButton {
                id: tab
                required property int index
                required property var session
                required property string title
                required property int state
                readonly property bool active: index === root.current

                width: tabs.tabWidth
                height: 34
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                onClicked: root.select(index)

                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    onTapped: root.closeTab(tab.index)
                }

                background: Rectangle {
                    radius: Theme.radius
                    color: !tab.active && tab.hovered ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                }

                contentItem: RowLayout {
                    spacing: 8
                    StatusDot { Layout.leftMargin: 12; state: tab.state }
                    Text {
                        Layout.fillWidth: true
                        text: tab.title
                        color: tab.active ? Theme.text : Theme.textDim
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontMd
                        font.weight: tab.active ? Font.Medium : Font.Normal
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                    }
                    IconButton {
                        Layout.rightMargin: 4
                        iconName: "x"; iconSize: 12
                        implicitWidth: 22; implicitHeight: 22
                        opacity: tab.hovered || tab.active ? 1 : 0
                        scale: tab.hovered || tab.active ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
                        Behavior on scale { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
                        tip: qsTr("Close  %1W").arg(Theme.modLabel)
                        onClicked: root.closeTab(tab.index)
                    }
                }
            }
        }

        IconButton {
            iconName: "plus"
            tip: qsTr("New session  %1T").arg(Theme.modLabel)
            onClicked: root.newTab()
        }
    }
}
