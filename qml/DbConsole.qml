import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// A standalone SQL Server console: connect, browse tables, run queries, read
// results. One window per connection; driven by a SqlSession from DbManager.
Window {
    id: win
    width: 1120
    height: 720
    minimumWidth: 720
    minimumHeight: 480
    color: Theme.bg
    title: (session ? session.host + (session.database ? " · " + session.database : "") : "SQL") + " — Perch SQL"

    property SqlSession session

    readonly property int st: session ? session.state : SqlSession.Idle
    readonly property bool connected: st === SqlSession.Connected || st === SqlSession.Executing
    readonly property bool busy: st === SqlSession.Connecting || st === SqlSession.Executing

    function run() {
        if (!session || !connected) return
        const sel = editor.selectedText
        session.execute(sel.length > 0 ? sel : editor.text)
    }
    function dispose() {
        if (session) DbManager.close(session)
        session = null
    }

    onClosing: dispose()

    // ---- Header ----
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 48
        color: Theme.sidebar
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 12
            spacing: 10
            Rectangle {
                width: 9; height: 9; radius: 5
                color: win.st === SqlSession.Connected ? Theme.success
                     : win.st === SqlSession.Executing ? Theme.accent
                     : win.st === SqlSession.Failed ? Theme.danger
                     : win.st === SqlSession.Connecting ? Theme.warning : Theme.textFaint
            }
            Text {
                text: session ? (session.username ? session.username + "@" : "") + session.host + ":" + session.port : ""
                color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.Medium
            }
            Text {
                visible: session && session.database !== ""
                text: session ? session.database : ""
                color: Theme.textDim; font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
            }
            Item { Layout.fillWidth: true }
            Text {
                text: session ? session.statusText : ""
                color: Theme.textDim; font.pixelSize: Theme.fontSm
            }
            GhostButton {
                visible: win.connected
                text: qsTr("Disconnect")
                onClicked: { session.disconnectSession() }
            }
        }
    }

    // ---- Connect gate (shown until a connection is live) ----
    Item {
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        visible: !win.connected

        Card {
            id: gate
            anchors.centerIn: parent
            width: 400
            implicitHeight: gcol.implicitHeight + padding * 2
            padding: 28
            elevation: 1.2

            function submit() {
                if (!session) return
                session.connectWith(pass.text)
            }

            ColumnLayout {
                id: gcol
                width: gate.width - gate.padding * 2
                spacing: 16

                Rectangle {
                    width: 44; height: 44; radius: 13
                    color: Theme.accentSoft
                    Icon { anchors.centerIn: parent; name: "lock"; size: 20; color: Theme.accent }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: qsTr("Connect to SQL Server")
                        color: Theme.text; font.pixelSize: Theme.fontXl; font.weight: Font.DemiBold
                    }
                    Text {
                        text: session ? (session.username ? session.username + "@" : "") + session.host + ":" + session.port
                                      + (session.database ? " / " + session.database : "") : ""
                        color: Theme.textFaint; font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
                        width: parent.width; elide: Text.ElideRight
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    visible: session && session.errorText !== ""
                    implicitHeight: gerr.implicitHeight + 18
                    radius: Theme.radius
                    color: Theme.dangerSoft
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 9; spacing: 8
                        Icon { name: "alert"; size: 14; color: Theme.danger }
                        Text {
                            id: gerr
                            Layout.fillWidth: true
                            text: session ? session.errorText : ""
                            color: Theme.danger; wrapMode: Text.WordWrap; font.pixelSize: Theme.fontSm
                        }
                    }
                }
                Field {
                    id: pass
                    Layout.fillWidth: true
                    label: qsTr("Password")
                    password: true
                    onAccepted: gate.submit()
                    Component.onCompleted: focusInput()
                }
                PrimaryButton {
                    Layout.fillWidth: true
                    text: win.st === SqlSession.Connecting ? qsTr("Connecting…") : qsTr("Connect")
                    iconName: "arrow-right"
                    enabled: win.st !== SqlSession.Connecting
                    onClicked: gate.submit()
                }
            }
        }
    }

    // ---- Workspace (tables | editor + results) ----
    RowLayout {
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        spacing: 0
        visible: win.connected

        // Tables sidebar.
        Rectangle {
            Layout.preferredWidth: 236
            Layout.fillHeight: true
            color: Theme.sidebar
            Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: Theme.border }
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    Layout.margins: 14
                    Layout.bottomMargin: 6
                    text: qsTr("TABLES & VIEWS")
                    color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                }
                ListView {
                    id: tablesList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: session ? session.tables : []
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        required property int index
                        required property string modelData
                        width: tablesList.width
                        height: 30
                        background: Rectangle {
                            color: hovered ? Theme.surface2 : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                        }
                        contentItem: RowLayout {
                            spacing: 8
                            Icon { Layout.leftMargin: 14; name: "monitor"; size: 13; color: Theme.textFaint }
                            Text {
                                Layout.fillWidth: true
                                text: modelData
                                color: Theme.textDim; font.pixelSize: Theme.fontSm
                                elide: Text.ElideMiddle
                            }
                        }
                        onClicked: {
                            editor.text = "SELECT TOP 100 * FROM " + modelData
                            win.run()
                        }
                    }
                }
            }
        }

        // Editor + results.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // SQL editor.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 170
                color: Theme.surface
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 10
                    anchors.bottomMargin: 44
                    clip: true
                    TextArea {
                        id: editor
                        text: "SELECT TOP 100 * FROM INFORMATION_SCHEMA.TABLES"
                        color: Theme.text
                        font.family: Theme.monoFamily
                        font.pixelSize: Theme.fontMd
                        selectByMouse: true
                        wrapMode: TextArea.NoWrap
                        placeholderText: qsTr("Write SQL — ⌘↵ to run")
                        background: null
                    }
                }
                RowLayout {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    anchors.margins: 8
                    spacing: 8
                    Text {
                        text: qsTr("⌘↵ runs the query (or the selection)")
                        color: Theme.textFaint; font.pixelSize: Theme.fontXs
                    }
                    Item { Layout.fillWidth: true }
                    PrimaryButton {
                        text: win.st === SqlSession.Executing ? qsTr("Running…") : qsTr("Run")
                        iconName: "arrow-right"
                        enabled: win.st === SqlSession.Connected
                        onClicked: win.run()
                    }
                }
            }

            // Results.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    visible: session && session.result.columns.length > 0

                    HorizontalHeaderView {
                        id: hhv
                        Layout.fillWidth: true
                        syncView: table
                        clip: true
                        delegate: Rectangle {
                            implicitHeight: 30
                            color: Theme.surface2
                            border.color: Theme.border
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                verticalAlignment: Text.AlignVCenter
                                text: display
                                color: Theme.textDim
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }
                    }
                    TableView {
                        id: table
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: session ? session.result : null
                        boundsBehavior: Flickable.StopAtBounds
                        columnWidthProvider: function (c) { return 180 }
                        rowHeightProvider: function (r) { return 28 }
                        ScrollBar.vertical: ScrollBar {}
                        ScrollBar.horizontal: ScrollBar {}
                        delegate: Rectangle {
                            implicitWidth: 180
                            implicitHeight: 28
                            color: (row % 2) ? Theme.bg : Theme.surface
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border; opacity: 0.5 }
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 6
                                verticalAlignment: Text.AlignVCenter
                                text: isNull ? "NULL" : display
                                color: isNull ? Theme.textFaint : Theme.text
                                font.italic: isNull === true
                                font.family: Theme.monoFamily
                                font.pixelSize: Theme.fontSm
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                // Message / empty state when a query returns no grid.
                Column {
                    anchors.centerIn: parent
                    spacing: 10
                    visible: !(session && session.result.columns.length > 0)
                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: win.st === SqlSession.Failed || (session && session.errorText) ? "alert" : "monitor"
                        size: 26
                        color: session && session.errorText ? Theme.danger : Theme.textFaint
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 420
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: session && session.errorText ? session.errorText
                            : session && session.message ? session.message
                            : qsTr("Run a query to see results.")
                        color: session && session.errorText ? Theme.danger : Theme.textDim
                        font.pixelSize: Theme.fontMd
                    }
                }
            }

            // Status bar.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                color: Theme.sidebar
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.border }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    Text {
                        text: session ? session.statusText : ""
                        color: Theme.textDim; font.pixelSize: Theme.fontXs
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: session && session.result.columns.length > 0
                        text: session ? session.result.rows + qsTr(" rows · ") + session.elapsedMs + " ms" : ""
                        color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                    }
                }
            }
        }
    }

    Shortcut { sequence: "Ctrl+Return"; onActivated: win.run() }
    Shortcut { sequence: "Meta+Return"; onActivated: win.run() }
    Shortcut { sequence: "Ctrl+Enter"; onActivated: win.run() }
    Shortcut { sequence: "Meta+Enter"; onActivated: win.run() }
}
