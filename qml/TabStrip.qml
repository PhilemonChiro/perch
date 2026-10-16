import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import Relay

Rectangle {
    id: root
    implicitHeight: 46
    color: Theme.bg

    property int current: -1
    property bool sidebarOpen: true
    readonly property var activeSession: (current >= 0 && current < SessionManager.count) ? SessionManager.at(current) : null
    readonly property bool sessionLive: activeSession && activeSession.phase === 2
    readonly property bool activeIsRdp: activeSession && activeSession.kind === "rdp"
    signal select(int index)
    signal closeTab(int index)
    signal showSidebar()
    signal newTab()
    signal fullscreen()
    signal toast(string message, string kind)

    function folderName(path) {
        if (!path) return ""
        const p = path.replace(/[\/\\]+$/, "")
        const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
        return i >= 0 ? p.substring(i + 1) : p
    }
    function applyShare(path) {
        if (!activeSession) return
        activeSession.shareFolder(path)
        if (activeSession.hostId !== "")
            ConnectionStore.setShare(activeSession.hostId, path)
        root.toast(path ? qsTr("Mounting “%1”…").arg(folderName(path))
                        : qsTr("Unmounting shared folder…"), "info")
    }

    FolderDialog {
        id: tsFolderDialog
        title: qsTr("Share a folder into this session")
        onAccepted: root.applyShare(ConnectionStore.toLocalPath(selectedFolder))
    }
    Menu {
        id: tsMountMenu
        padding: 6
        background: Rectangle { implicitWidth: 220; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
            NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
        delegate: MenuItem {
            id: tmi
            implicitHeight: 30
            readonly property bool danger: text === qsTr("Unmount folder")
            contentItem: Text { leftPadding: 4; text: tmi.text; color: tmi.danger ? Theme.danger : Theme.text; font.pixelSize: Theme.fontMd; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { radius: Theme.radiusSm; color: tmi.highlighted ? (tmi.danger ? Theme.dangerSoft : Theme.surface3) : "transparent" }
        }
        Action { text: qsTr("Change folder…"); onTriggered: tsFolderDialog.open() }
        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
        Action { text: qsTr("Unmount folder"); onTriggered: root.applyShare("") }
    }

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
                required property string kind
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
                    // Kind icon carries the colour tag (blue = RDP, violet = SQL);
                    // a corner dot carries the live phase.
                    Item {
                        Layout.leftMargin: 12
                        implicitWidth: 16; implicitHeight: 16
                        Icon {
                            anchors.centerIn: parent
                            name: tab.kind === "sql" ? "database" : "monitor"
                            size: 14
                            color: Theme.kindColor(tab.kind)
                            opacity: tab.active ? 1 : 0.75
                        }
                        Rectangle {
                            visible: tab.state !== 0
                            width: 6; height: 6; radius: 3
                            color: Theme.phaseColor(tab.state)
                            border.width: 1.5; border.color: Theme.bg
                            anchors { right: parent.right; bottom: parent.bottom; rightMargin: -1; bottomMargin: -1 }
                        }
                    }
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

        // Contextual controls for the active RDP session (folder share, fullscreen,
        // disconnect). SQL tabs carry their own controls inside the page.
        Row {
            spacing: 2
            visible: root.activeIsRdp
            Rectangle { width: 1; height: 18; color: Theme.border; anchors.verticalCenter: parent.verticalCenter }
            IconButton {
                id: tsShare
                iconName: "folder"; iconSize: 15
                enabled: root.sessionLive
                opacity: enabled ? 1 : 0.4
                readonly property string shared: root.activeIsRdp ? root.activeSession.sharedFolder : ""
                checked: shared !== ""
                tip: shared !== "" ? qsTr("Sharing “%1” — click to change").arg(root.folderName(shared))
                                   : qsTr("Share a folder into this session")
                onClicked: shared !== "" ? tsMountMenu.popup(tsShare, 0, tsShare.height + 4) : tsFolderDialog.open()
                Rectangle {
                    visible: tsShare.checked
                    width: 5; height: 5; radius: 3; color: Theme.accent
                    anchors { right: parent.right; top: parent.top; rightMargin: 5; topMargin: 5 }
                }
            }
            IconButton {
                iconName: "expand"; iconSize: 15
                tip: qsTr("Full screen  %1↵").arg(Theme.modLabel)
                onClicked: root.fullscreen()
            }
            IconButton {
                iconName: "power"; iconSize: 15; danger: true
                tip: qsTr("Disconnect  %1W").arg(Theme.modLabel)
                onClicked: if (root.activeSession) root.activeSession.disconnect()
            }
        }

        Rectangle { width: 1; height: 18; color: Theme.border; visible: root.activeIsRdp }

        IconButton {
            iconName: "plus"
            tip: qsTr("New session  %1T").arg(Theme.modLabel)
            onClicked: root.newTab()
        }
    }
}
