import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Shapes
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
            background: Rectangle { radius: Theme.radiusSm; color: tmi.highlighted ? (tmi.danger ? Theme.dangerSoft : Theme.hover) : "transparent" }
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
            Layout.fillHeight: true
            Layout.topMargin: 8
            orientation: ListView.Horizontal
            // Tabs are slanted trapezoids that overlap: each tab's angled edge
            // tucks under its neighbour, and the active one rises to the front.
            readonly property int slant: 18
            spacing: -slant
            clip: true
            model: SessionManager
            currentIndex: root.current
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentWidth > width
            // Compact tabs: shrink toward content when there's room, only growing
            // up to a modest cap, so a couple of tabs don't sprawl across the bar.
            readonly property real tabWidth: count ? Math.max(118, Math.min(190, (width + slant * (count - 1)) / count + slant)) : 190

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
                readonly property color kc: (tab.kind === "sql" && tab.session)
                    ? Theme.engineColor(tab.session.engine) : Theme.kindColor(tab.kind)
                // Context that distinguishes two tabs to the same host: the
                // database for SQL, the sign-in user for RDP.
                readonly property string subtitle: {
                    if (!tab.session) return ""
                    if (tab.kind === "sql") return tab.session.currentDatabase || tab.session.database || ""
                    return tab.session.username || ""
                }

                width: tabs.tabWidth
                height: tabs.height
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                onClicked: root.select(index)
                // Active tab on top; otherwise left tabs overlap those to the right.
                z: tab.active ? 1000 : (500 - index)

                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    onTapped: root.closeTab(tab.index)
                }

                // Chrome-style tab: curved S-shaped sides that flare out to the
                // baseline where the tab meets the toolbar below. The active tab
                // fills with the content surface so it reads as connected (no
                // underline); the outline skips the bottom edge.
                background: Shape {
                    id: tabShape
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    readonly property real s: tabs.slant
                    readonly property real w: tab.width
                    readonly property real h: tab.height
                    ShapePath {
                        strokeWidth: 0
                        strokeColor: "transparent"
                        fillColor: tab.active ? Theme.surface : (tab.hovered ? Theme.surface2 : Theme.sidebar)
                        startX: 0; startY: tabShape.h
                        // Left side: flare up from the baseline into the top edge.
                        PathCubic {
                            control1X: tabShape.s * 0.82; control1Y: tabShape.h
                            control2X: tabShape.s * 0.18; control2Y: 0
                            x: tabShape.s; y: 0
                        }
                        PathLine { x: tabShape.w - tabShape.s; y: 0 }
                        // Right side: ease back down to the baseline.
                        PathCubic {
                            control1X: tabShape.w - tabShape.s * 0.18; control1Y: 0
                            control2X: tabShape.w - tabShape.s * 0.82; control2Y: tabShape.h
                            x: tabShape.w; y: tabShape.h
                        }
                        PathLine { x: 0; y: tabShape.h }
                    }
                    ShapePath {
                        strokeWidth: 1
                        strokeColor: tab.active ? Theme.borderStrong : Theme.border
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        startX: 0; startY: tabShape.h
                        PathCubic {
                            control1X: tabShape.s * 0.82; control1Y: tabShape.h
                            control2X: tabShape.s * 0.18; control2Y: 0
                            x: tabShape.s; y: 0
                        }
                        PathLine { x: tabShape.w - tabShape.s; y: 0 }
                        PathCubic {
                            control1X: tabShape.w - tabShape.s * 0.18; control1Y: 0
                            control2X: tabShape.w - tabShape.s * 0.82; control2Y: tabShape.h
                            x: tabShape.w; y: tabShape.h
                        }
                    }
                }

                contentItem: RowLayout {
                    spacing: 9
                    // A filled, colour-tagged chip makes the kind unmistakable at
                    // a glance (violet = SQL, blue = RDP); a corner dot shows phase.
                    Rectangle {
                        Layout.leftMargin: tabs.slant + 4
                        implicitWidth: 24; implicitHeight: 24
                        radius: Theme.radiusSm
                        color: Qt.rgba(tab.kc.r, tab.kc.g, tab.kc.b, tab.active ? 0.2 : 0.13)
                        Icon {
                            anchors.centerIn: parent
                            name: tab.kind === "sql" ? "database" : "monitor"
                            size: 14
                            color: tab.kc
                            opacity: tab.active ? 1 : 0.82
                        }
                        Rectangle {
                            visible: tab.state !== 0
                            width: 7; height: 7; radius: 3.5
                            color: Theme.phaseColor(tab.state)
                            border.width: 1.5; border.color: Theme.bg
                            anchors { right: parent.right; bottom: parent.bottom; rightMargin: -2; bottomMargin: -2 }
                        }
                    }
                    // Two-line label: host on top, context (db / user) beneath.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: tab.title
                            color: tab.active ? Theme.text : Theme.textDim
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSm
                            font.weight: tab.active ? Font.DemiBold : Font.Medium
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: tab.subtitle !== ""
                            text: (tab.kind === "sql" ? "" : "@") + tab.subtitle
                            color: tab.active ? tab.kc : Theme.textFaint
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontXs
                            font.family: tab.kind === "sql" ? Theme.fontFamily : Theme.monoFamily
                        }
                    }
                    IconButton {
                        Layout.rightMargin: tabs.slant - 4
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
