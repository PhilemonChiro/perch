import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

ApplicationWindow {
    id: win
    width: 1320
    height: 840
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: current >= 0 && SessionManager.at(current) ? SessionManager.at(current).title + " — Relay" : "Relay"
    color: Theme.bg
    font.family: Theme.fontFamily

    // -1 shows Home; otherwise the index of the active session tab.
    property int current: -1
    readonly property int sidebarW: 268

    // The sidebar docks (pushing content) on Home or when the user pins it;
    // while connected it tucks away and floats back in on a left-edge hover.
    property bool sidebarPinned: false
    property bool edgeHover: false
    property bool sidebarHover: false
    readonly property bool fullscreen: visibility === Window.FullScreen
    readonly property bool sidebarDocked: !fullscreen && (current < 0 || sidebarPinned)
    readonly property bool sidebarPeek: !fullscreen && !sidebarDocked && (edgeHover || sidebarHover)
    readonly property bool sidebarShown: sidebarDocked || sidebarPeek
    // Back-compat alias for children that ask whether the sidebar is on screen.
    readonly property bool sidebarOpen: sidebarShown

    function toast(msg, kind) { toaster.show(msg, kind) }
    function closeTab(i) { if (i >= 0) SessionManager.close(i) }
    function toggleFullscreen() {
        win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
    }

    Connections {
        target: SessionManager
        function onOpened(i) {
            win.current = i
            // Tuck the sidebar away as soon as a session opens, even if the pointer
            // is still over it (the hover handlers re-arm on the next enter).
            win.sidebarPinned = false
            win.sidebarHover = false
            win.edgeHover = false
        }
        function onRowsRemoved(parent, first, last) {
            const n = SessionManager.count
            if (win.current > last) win.current -= (last - first + 1)
            else if (win.current >= first) win.current = n === 0 ? -1 : Math.min(first, n - 1)
        }
    }

    Shortcut { sequences: [Theme.seq("K"), Theme.seq("T")]; context: Qt.ApplicationShortcut; onActivated: palette.toggle() }
    Shortcut { sequence: Theme.seq("N"); context: Qt.ApplicationShortcut; onActivated: editor.openNew("") }
    Shortcut { sequence: Theme.seq("W"); context: Qt.ApplicationShortcut; onActivated: win.closeTab(win.current) }
    Shortcut { sequence: Theme.seq("B"); context: Qt.ApplicationShortcut; onActivated: win.sidebarPinned = !win.sidebarPinned }
    Shortcut { sequence: Theme.seq("Return"); context: Qt.ApplicationShortcut; onActivated: win.toggleFullscreen() }
    Shortcut {
        sequence: Theme.seq("]"); context: Qt.ApplicationShortcut
        onActivated: if (SessionManager.count) win.current = (win.current + 1) % SessionManager.count
    }
    Shortcut {
        sequence: Theme.seq("["); context: Qt.ApplicationShortcut
        onActivated: if (SessionManager.count) win.current = win.current <= 0 ? SessionManager.count - 1 : win.current - 1
    }
    Shortcut { sequence: Theme.seq("0"); context: Qt.ApplicationShortcut; onActivated: win.current = -1 }
    Repeater {
        model: 9
        delegate: Item {
            required property int index
            Shortcut {
                sequence: Theme.seq(String(index + 1)); context: Qt.ApplicationShortcut
                onActivated: if (index < SessionManager.count) win.current = index
            }
        }
    }

    Item {
        anchors.fill: parent

        // Main content. Docked sidebar pushes it right; a peeking sidebar floats over it.
        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: win.sidebarDocked ? win.sidebarW : 0
            Behavior on anchors.leftMargin { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutQuint } }
            spacing: 0

            TabStrip {
                Layout.fillWidth: true
                visible: !win.fullscreen
                current: win.current
                sidebarOpen: win.sidebarDocked
                onSelect: i => win.current = i
                onCloseTab: i => win.closeTab(i)
                onShowSidebar: win.sidebarPinned = true
                onNewTab: palette.open()
            }

            Item {
                id: stage
                Layout.fillWidth: true
                Layout.fillHeight: true

                Home {
                    anchors.fill: parent
                    opacity: win.current < 0 ? 1 : 0
                    visible: opacity > 0
                    scale: win.current < 0 ? 1 : 0.985
                    Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                    Behavior on scale { NumberAnimation { duration: Theme.slow; easing.type: Theme.easing } }
                    onConnectHost: id => SessionManager.openHost(id)
                    onQuickConnect: text => {
                        if (SessionManager.quickConnect(text) < 0) win.toast(qsTr("That doesn’t look like a host address"), "error")
                    }
                    onNewHost: editor.openNew("")
                    onOpenPalette: palette.open()
                }

                Repeater {
                    model: SessionManager
                    delegate: SessionPage {
                        required property int index
                        required property var session
                        anchors.fill: parent
                        sessionObj: session
                        active: index === win.current
                        opacity: active ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                        onCloseRequested: win.closeTab(index)
                        onFullscreenRequested: win.toggleFullscreen()
                        onSaveRequested: editor.openFromSession(session)
                    }
                }
            }
        }

        // Thin left-edge trigger: hovering it floats the tucked-away sidebar back in.
        Item {
            width: 12
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            visible: !win.sidebarDocked && !win.fullscreen
            z: 40
            HoverHandler { onHoveredChanged: win.edgeHover = hovered }
        }

        // Sidebar overlay: docked slides flush with the content, peeking floats above it.
        Item {
            width: win.sidebarW + 16   // room for the floating shadow
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            x: win.sidebarShown ? 0 : -width
            z: 50
            Behavior on x { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutQuint } }
            HoverHandler { onHoveredChanged: win.sidebarHover = hovered }

            // Shadow, only while floating over a session.
            Rectangle {
                anchors { left: panel.right; top: parent.top; bottom: parent.bottom }
                width: 16
                opacity: win.sidebarDocked ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.28) }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            Sidebar {
                id: panel
                width: win.sidebarW
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                clip: true
                onConnectHost: id => SessionManager.openHost(id)
                onEditHost: id => editor.openEdit(id)
                onNewHost: folderId => editor.openNew(folderId)
                onOpenPalette: palette.open()
                onCollapse: win.sidebarPinned = false
                onToast: (m, k) => win.toast(m, k)

                // Right divider, shown when docked flush against the content.
                Rectangle {
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    width: 1
                    color: Theme.border
                    visible: win.sidebarDocked
                }
            }
        }
    }

    CommandPalette {
        id: palette
        onConnectHost: id => SessionManager.openHost(id)
        onQuickConnect: text => {
            if (SessionManager.quickConnect(text) < 0) win.toast(qsTr("That doesn’t look like a host address"), "error")
        }
        onNewHost: editor.openNew("")
        onNewFolder: { ConnectionStore.addFolder(qsTr("New folder"), ""); win.sidebarPinned = true }
        onGoHome: win.current = -1
        onToggleTheme: Theme.mode = Theme.dark ? "light" : "dark"
    }

    ConnectionEditor {
        id: editor
        onSaved: (name, connect, id) => {
            win.toast(qsTr("Saved %1").arg(name), "success")
            if (connect) SessionManager.openHost(id)
        }
        onDeleted: name => win.toast(qsTr("Deleted %1").arg(name))
    }

    Toast {
        id: toaster
        z: 100
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 20
    }
}
