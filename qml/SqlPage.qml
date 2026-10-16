import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// A SQL Server console tab: connect, pick a database, browse its tables, run
// queries, read results. The live connection pauses after inactivity; the tab
// and its editor stay, and running a query resumes it.
Item {
    id: page
    clip: true

    property var sessionObj
    property bool active: false
    signal closeRequested()
    signal toast(string message, string kind)

    readonly property int st: sessionObj ? sessionObj.state : 0
    // Once we've connected at least once the database list is populated; that's
    // our gate: before it, show the password form; after, the workspace (even
    // when paused/disconnected, so the editor and results survive).
    readonly property bool everConnected: sessionObj && sessionObj.databases.length > 0
    readonly property bool live: st === SqlSession.Connected
    readonly property bool busy: st === SqlSession.Connecting || st === SqlSession.Executing
    readonly property bool paused: st === SqlSession.Paused || st === SqlSession.Disconnected

    function run() {
        if (!sessionObj) return
        const sel = editor.selectedText
        sessionObj.execute(sel.length > 0 ? sel : editor.text)
    }

    onActiveChanged: if (active && everConnected) editor.forceActiveFocus()

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // ---- Connect gate (first connection only) ----
    Item {
        anchors.fill: parent
        visible: !page.everConnected

        Card {
            id: gate
            anchors.centerIn: parent
            width: 400
            implicitHeight: gcol.implicitHeight + padding * 2
            padding: 28
            elevation: 1.2

            function submit() { if (sessionObj) sessionObj.connectWith(pass.text) }

            ColumnLayout {
                id: gcol
                width: gate.width - gate.padding * 2
                spacing: 16

                Rectangle {
                    width: 44; height: 44; radius: 13
                    color: Qt.rgba(Theme.sqlTag.r, Theme.sqlTag.g, Theme.sqlTag.b, 0.14)
                    Icon { anchors.centerIn: parent; name: "database"; size: 20; color: Theme.sqlTag }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: qsTr("Connect to SQL Server")
                        color: Theme.text; font.pixelSize: Theme.fontXl; font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width; elide: Text.ElideRight
                        text: sessionObj ? (sessionObj.username ? sessionObj.username + "@" : "")
                                         + sessionObj.host + ":" + sessionObj.port
                                         + (sessionObj.database ? " / " + sessionObj.database : "") : ""
                        color: Theme.textFaint; font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    visible: sessionObj && sessionObj.errorText !== ""
                    implicitHeight: gerr.implicitHeight + 18
                    radius: Theme.radius
                    color: Theme.dangerSoft
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 9; spacing: 8
                        Icon { name: "alert"; size: 14; color: Theme.danger }
                        Text {
                            id: gerr
                            Layout.fillWidth: true
                            text: sessionObj ? sessionObj.errorText : ""
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
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    GhostButton { text: qsTr("Cancel"); onClicked: page.closeRequested() }
                    PrimaryButton {
                        Layout.fillWidth: true
                        text: page.st === SqlSession.Connecting ? qsTr("Connecting…") : qsTr("Connect")
                        iconName: "arrow-right"
                        enabled: page.st !== SqlSession.Connecting
                        onClicked: gate.submit()
                    }
                }
            }
        }
    }

    // ---- Workspace ----
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: page.everConnected

        // Toolbar: database switcher + status + resume/disconnect.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            color: Theme.surface
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                Icon { name: "database"; size: 15; color: Theme.sqlTag }
                // Database context switcher.
                ComboBox {
                    id: dbPicker
                    Layout.preferredWidth: 220
                    model: sessionObj ? sessionObj.databases : []
                    enabled: page.live
                    currentIndex: sessionObj ? sessionObj.databases.indexOf(sessionObj.currentDatabase) : -1
                    onActivated: if (sessionObj) sessionObj.useDatabase(currentValue)

                    contentItem: Text {
                        leftPadding: 12; rightPadding: 28
                        text: sessionObj ? (sessionObj.currentDatabase || qsTr("(select database)")) : ""
                        color: Theme.text; font.pixelSize: Theme.fontMd
                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                    }
                    background: Rectangle {
                        implicitHeight: 32; radius: Theme.radius
                        color: dbPicker.hovered ? Theme.surface2 : Theme.surface
                        border.color: dbPicker.hovered ? Theme.borderStrong : Theme.border
                    }
                    indicator: Icon {
                        x: dbPicker.width - width - 10; y: (dbPicker.height - height) / 2
                        name: "chevron"; size: 12; color: Theme.textFaint; rotation: 90
                    }
                    popup: Popup {
                        y: dbPicker.height + 4; width: dbPicker.width
                        implicitHeight: Math.min(contentItem.implicitHeight + 12, 320)
                        padding: 6
                        background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: dbPicker.popup.visible ? dbPicker.delegateModel : null
                            ScrollBar.vertical: ScrollBar {}
                        }
                    }
                    delegate: ItemDelegate {
                        required property int index
                        required property string modelData
                        width: dbPicker.width - 12
                        height: 30
                        contentItem: Text {
                            text: modelData; color: Theme.text; font.pixelSize: Theme.fontSm
                            verticalAlignment: Text.AlignVCenter; leftPadding: 6; elide: Text.ElideRight
                        }
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: highlighted ? Theme.surface3 : "transparent"
                        }
                        highlighted: dbPicker.highlightedIndex === index
                        onClicked: { dbPicker.currentIndex = index; sessionObj.useDatabase(modelData); dbPicker.popup.close() }
                    }
                }
                Text {
                    text: sessionObj ? qsTr("%1 tables").arg(sessionObj.tables.length) : ""
                    color: Theme.textFaint; font.pixelSize: Theme.fontXs
                }

                Item { Layout.fillWidth: true }

                // Paused indicator.
                RowLayout {
                    spacing: 6
                    visible: page.paused
                    Rectangle { width: 7; height: 7; radius: 4; color: Theme.textFaint }
                    Text { text: qsTr("Paused"); color: Theme.textDim; font.pixelSize: Theme.fontSm }
                }
                GhostButton {
                    visible: page.paused
                    text: qsTr("Resume")
                    onClicked: sessionObj.reconnect()
                }
                GhostButton {
                    visible: page.live
                    text: qsTr("Disconnect")
                    onClicked: sessionObj.disconnectSession()
                }
            }
        }

        // Tables | editor + results.
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

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
                        model: sessionObj ? sessionObj.tables : []
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
                                Icon { Layout.leftMargin: 14; name: "database"; size: 12; color: Theme.textFaint }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    color: Theme.textDim; font.pixelSize: Theme.fontSm
                                    elide: Text.ElideMiddle
                                }
                            }
                            onClicked: { editor.text = "SELECT TOP 100 * FROM " + modelData; page.run() }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Editor.
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
                            text: page.paused ? qsTr("Paused — ⌘↵ resumes and runs")
                                              : qsTr("⌘↵ runs the query (or the selection)")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                        }
                        Item { Layout.fillWidth: true }
                        PrimaryButton {
                            text: page.st === SqlSession.Executing ? qsTr("Running…")
                                : page.st === SqlSession.Connecting ? qsTr("Resuming…")
                                : page.paused ? qsTr("Resume & run") : qsTr("Run")
                            iconName: "arrow-right"
                            enabled: !page.busy
                            onClicked: page.run()
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
                        visible: sessionObj && sessionObj.result.columns.length > 0

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
                                    anchors.fill: parent; anchors.leftMargin: 10
                                    verticalAlignment: Text.AlignVCenter
                                    text: display
                                    color: Theme.textDim; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        TableView {
                            id: table
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: sessionObj ? sessionObj.result : null
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
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                                    verticalAlignment: Text.AlignVCenter
                                    text: isNull ? "NULL" : display
                                    color: isNull ? Theme.textFaint : Theme.text
                                    font.italic: isNull === true
                                    font.family: Theme.monoFamily; font.pixelSize: Theme.fontSm
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 10
                        visible: !(sessionObj && sessionObj.result.columns.length > 0)
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: sessionObj && sessionObj.errorText ? "alert" : "database"
                            size: 26
                            color: sessionObj && sessionObj.errorText ? Theme.danger : Theme.textFaint
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 420; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            text: sessionObj && sessionObj.errorText ? sessionObj.errorText
                                : sessionObj && sessionObj.message ? sessionObj.message
                                : qsTr("Run a query to see results.")
                            color: sessionObj && sessionObj.errorText ? Theme.danger : Theme.textDim
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
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                        Text {
                            text: sessionObj ? sessionObj.statusText : ""
                            color: Theme.textDim; font.pixelSize: Theme.fontXs
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: sessionObj && sessionObj.result.columns.length > 0
                            text: sessionObj ? sessionObj.result.rows + qsTr(" rows · ") + sessionObj.elapsedMs + " ms" : ""
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                        }
                    }
                }
            }
        }
    }

    Shortcut { sequence: "Ctrl+Return"; enabled: page.active; onActivated: page.run() }
    Shortcut { sequence: "Meta+Return"; enabled: page.active; onActivated: page.run() }
    Shortcut { sequence: "Ctrl+Enter"; enabled: page.active; onActivated: page.run() }
    Shortcut { sequence: "Meta+Enter"; enabled: page.active; onActivated: page.run() }
}
