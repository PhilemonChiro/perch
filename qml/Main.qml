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

    // Shown on Home or when the user pins it; tucked away while a session is active.
    property bool sidebarPinned: false
    readonly property bool fullscreen: visibility === Window.FullScreen
    readonly property bool sidebarDocked: !fullscreen && (current < 0 || sidebarPinned)

    function toast(msg, kind) { toaster.show(msg, kind) }
    function closeTab(i) { if (i >= 0) SessionManager.close(i) }
    function toggleFullscreen() {
        win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
    }

    Connections {
        target: SessionManager
        function onOpened(i) {
            win.current = i
            win.sidebarPinned = false // tuck the sidebar away when a session opens
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

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Sidebar docks (pushing content) on Home or when pinned; it tucks away to
        // zero width while a session is active. Reveal it with the tab-strip button
        // or Cmd+B — predictable, no hover-reveal over the remote desktop.
        Sidebar {
            id: sidebar
            Layout.fillHeight: true
            Layout.preferredWidth: win.sidebarDocked ? win.sidebarW : 0
            clip: true
            Behavior on Layout.preferredWidth { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutQuint } }
            onConnectHost: id => SessionManager.openHost(id)
            onEditHost: id => editor.openEdit(id)
            onNewHost: folderId => editor.openNew(folderId)
            onOpenPalette: palette.open()
            onCollapse: win.sidebarPinned = false
            onToast: (m, k) => win.toast(m, k)
        }
        Rectangle {
            Layout.fillHeight: true
            width: 1
            color: Theme.border
            visible: sidebar.Layout.preferredWidth > 0
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
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
