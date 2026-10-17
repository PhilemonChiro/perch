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
    // Editor pane height — adjustable by dragging the divider below it.
    property real editorHeight: 170
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

    // Saved queries are grouped by the server they belong to ("host:port").
    readonly property string serverKey: sessionObj ? (sessionObj.host + ":" + sessionObj.port) : ""
    property var savedQueries: []
    function refreshSaved() { savedQueries = serverKey !== "" ? QueryStore.forServer(serverKey) : [] }
    Connections {
        target: QueryStore
        function onChanged(server) { if (server === page.serverKey) page.refreshSaved() }
    }
    Component.onCompleted: refreshSaved()

    // The SQL that "Save" would store: the selection if any, else the whole editor.
    readonly property string sqlToSave: editor && editor.selectedText.length > 0 ? editor.selectedText
                                       : (editor ? editor.text : "")
    function saveQuery(name) {
        const sql = page.sqlToSave
        if (sql.trim() === "" || serverKey === "") return false
        const nm = (name && name.trim() !== "") ? name.trim() : page.summarizeQuery(sql)
        QueryStore.save(serverKey, nm, sql)
        page.toast(qsTr("Query saved"), "info")
        return true
    }

    // Builds a short, human-readable name from SQL — no network, fully local.
    // Handles the common SELECT/UPDATE/INSERT/DELETE/DDL/EXEC shapes and falls
    // back to a structural label (joins/group/CTE/multi-statement) for the rest.
    function summarizeQuery(sqlRaw) {
        if (!sqlRaw) return ""
        let s = sqlRaw.replace(/\/\*[\s\S]*?\*\//g, " ")
                      .replace(/--[^\n]*/g, " ")
                      .replace(/\s+/g, " ").trim()
        if (s === "") return ""
        const parts = s.split(";").map(x => x.trim()).filter(x => x.length > 0)
        const extra = parts.length > 1 ? " (+" + (parts.length - 1) + " more)" : ""
        s = parts[0]
        const T = "([\\[\\]\\w.#@$\"]+)"
        const lastName = (t) => {
            if (!t) return ""
            t = t.replace(/[\[\]"]/g, "")
            const seg = t.split(".")
            return seg[seg.length - 1]
        }
        const tableAfter = (kw) => {
            const m = s.match(new RegExp("\\b" + kw + "\\s+" + T, "i"))
            return m ? lastName(m[1]) : ""
        }
        const whereCol = () => {
            const w = s.match(/\bwhere\s+(?:cast\s*\(\s*)?\[?(\w+)\]?/i)
            return w ? w[1] : ""
        }
        const joins = (s.match(/\bjoin\b/gi) || []).length
        const grouped = /\bgroup\s+by\s+\[?(\w+)\]?/i.exec(s)

        let name = ""
        if (/^\s*select\b/i.test(s)) {
            const t = tableAfter("from")
            const col = whereCol()
            if (!t) name = qsTr("Query")
            else if (grouped) name = qsTr("%1 grouped by %2").arg(t).arg(grouped[1])
            else if (joins > 0) name = qsTr("%1 + %n join(s)", "", joins).arg(t)
            else if (col) name = qsTr("Find %1 by %2").arg(t).arg(col)
            else {
                const top = s.match(/\btop\s+(\d+)/i)
                name = top ? qsTr("Top %1 %2").arg(top[1]).arg(t) : t
            }
        } else if (/^\s*update\b/i.test(s)) {
            const t = tableAfter("update"); const col = whereCol()
            name = col ? qsTr("Update %1 by %2").arg(t || "table").arg(col)
                       : qsTr("Update %1").arg(t || "table")
        } else if (/^\s*insert\b/i.test(s)) {
            name = qsTr("Insert into %1").arg(tableAfter("into") || "table")
        } else if (/^\s*delete\b/i.test(s)) {
            const t = tableAfter("from"); const col = whereCol()
            name = col ? qsTr("Delete from %1 by %2").arg(t || "table").arg(col)
                       : qsTr("Delete from %1").arg(t || "table")
        } else if (/^\s*(create|alter|drop)\s+(table|view|proc|procedure|function|index)\b/i.test(s)) {
            const mm = s.match(/^\s*(create|alter|drop)\s+(?:table|view|proc|procedure|function|index)\s+(?:if\s+(?:not\s+)?exists\s+)?([\[\]\w.#@$"]+)/i)
            const verb = mm ? mm[1][0].toUpperCase() + mm[1].slice(1).toLowerCase() : qsTr("Change")
            name = verb + " " + (mm ? lastName(mm[2]) : qsTr("object"))
        } else if (/^\s*exec(ute)?\b/i.test(s)) {
            const mm = s.match(/^\s*exec(?:ute)?\s+([\[\]\w.#@$"]+)/i)
            name = qsTr("Run %1").arg(mm ? lastName(mm[1]) : qsTr("procedure"))
        } else if (/^\s*with\b/i.test(s)) {
            name = qsTr("CTE query")
        } else {
            name = s.slice(0, 48)
        }
        name += extra
        return name.length > 60 ? name.slice(0, 60) : name
    }
    function loadQuery(sql) { editor.text = sql; editor.forceActiveFocus() }
    function runSaved(sql) { editor.text = sql; if (sessionObj) sessionObj.execute(sql) }
    function fmtAgo(iso) {
        if (!iso) return ""
        const d = new Date(iso)
        const s = (Date.now() - d.getTime()) / 1000
        if (s < 45) return qsTr("just now")
        if (s < 3600) return qsTr("%1m ago").arg(Math.floor(s / 60))
        if (s < 86400) return qsTr("%1h ago").arg(Math.floor(s / 3600))
        if (s < 604800) return qsTr("%1d ago").arg(Math.floor(s / 86400))
        return Qt.formatDate(d, "MMM d")
    }

    function run() {
        if (!sessionObj) return
        const sel = editor.selectedText
        sessionObj.execute(sel.length > 0 ? sel : editor.text)
    }
    function fmtSize(kb) {
        if (kb < 0) return ""
        if (kb < 1024) return kb + " KB"
        if (kb < 1048576) return (kb / 1024).toFixed(1) + " MB"
        return (kb / 1048576).toFixed(2) + " GB"
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

            function submit() { if (sessionObj) sessionObj.connectWith(pass.text, remember.checked) }

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
                Toggle {
                    id: remember
                    // Only saved connections can persist a password.
                    visible: sessionObj && sessionObj.hostId !== ""
                    checked: true
                    label: qsTr("Remember in keychain")
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

                // Database context switcher with search (carries its own icon).
                Item {
                    id: dbSwitch
                    Layout.preferredWidth: 240
                    implicitHeight: 32
                    enabled: page.live

                    AbstractButton {
                        anchors.fill: parent
                        hoverEnabled: true
                        focusPolicy: Qt.NoFocus
                        opacity: dbSwitch.enabled ? 1 : 0.5
                        onClicked: { dbPop.open(); dbSearch.forceActiveFocus() }
                        background: Rectangle {
                            radius: Theme.radius
                            color: parent.hovered ? Theme.surface2 : Theme.surface
                            border.color: dbPop.visible ? Theme.accent : (parent.hovered ? Theme.borderStrong : Theme.border)
                        }
                        contentItem: RowLayout {
                            spacing: 6
                            Icon { Layout.leftMargin: 10; name: "database"; size: 13; color: Theme.sqlTag }
                            Text {
                                Layout.fillWidth: true
                                text: sessionObj ? (sessionObj.currentDatabase || qsTr("(select database)")) : ""
                                color: Theme.text; font.pixelSize: Theme.fontMd
                                verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                            }
                            Icon { Layout.rightMargin: 10; name: "chevron"; size: 11; color: Theme.textFaint; rotation: 90 }
                        }
                    }

                    Popup {
                        id: dbPop
                        y: dbSwitch.height + 4
                        width: 280
                        implicitHeight: Math.min(dbCol.implicitHeight + 12, 360)
                        padding: 6
                        onClosed: dbSearch.clear()
                        background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }

                        readonly property var filtered: {
                            const all = sessionObj ? sessionObj.databases : []
                            const q = dbSearch.text.trim().toLowerCase()
                            return q === "" ? all : all.filter(d => d.toLowerCase().indexOf(q) !== -1)
                        }

                        contentItem: ColumnLayout {
                            id: dbCol
                            spacing: 6
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 30
                                radius: Theme.radius
                                color: Theme.surface
                                border.color: dbSearch.activeFocus ? Theme.accent : Theme.border
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 9; anchors.rightMargin: 8
                                    spacing: 6
                                    Icon { name: "search"; size: 13; color: Theme.textFaint }
                                    TextField {
                                        id: dbSearch
                                        Layout.fillWidth: true
                                        padding: 0; background: null
                                        color: Theme.text; font.pixelSize: Theme.fontSm
                                        placeholderText: qsTr("Search databases")
                                        placeholderTextColor: Theme.textFaint
                                        onAccepted: if (dbPop.filtered.length > 0) { sessionObj.useDatabase(dbPop.filtered[0]); dbPop.close() }
                                    }
                                }
                            }
                            ListView {
                                id: dbList
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(contentHeight, 280)
                                clip: true
                                model: dbPop.filtered
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: ScrollBar {}
                                property int hoveredIndex: -1
                                HoverHandler { onHoveredChanged: if (!hovered) dbList.hoveredIndex = -1 }
                                delegate: ItemDelegate {
                                    id: dbd
                                    required property int index
                                    required property string modelData
                                    width: dbList.width
                                    height: 30
                                    readonly property bool current: sessionObj && sessionObj.currentDatabase === modelData
                                    readonly property bool hov: dbList.hoveredIndex === dbd.index
                                    HoverHandler {
                                        onHoveredChanged: {
                                            if (hovered) dbList.hoveredIndex = dbd.index
                                            else if (dbList.hoveredIndex === dbd.index) dbList.hoveredIndex = -1
                                        }
                                    }
                                    contentItem: RowLayout {
                                        spacing: 6
                                        Text {
                                            Layout.fillWidth: true; Layout.leftMargin: 6
                                            text: modelData
                                            color: dbd.current ? Theme.sqlTag : Theme.text
                                            font.pixelSize: Theme.fontSm
                                            font.weight: dbd.current ? Font.DemiBold : Font.Normal
                                            elide: Text.ElideRight
                                        }
                                    }
                                    background: Rectangle {
                                        radius: Theme.radiusSm
                                        color: dbd.current ? Theme.accentSoft : (dbd.hov ? Theme.hover : "transparent")
                                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                                    }
                                    onClicked: { sessionObj.useDatabase(modelData); dbPop.close() }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: dbList.count === 0
                                    text: qsTr("No matches")
                                    color: Theme.textFaint; font.pixelSize: Theme.fontSm
                                }
                            }
                        }
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

                    readonly property var filteredTables: {
                        const all = sessionObj ? sessionObj.tables : []
                        const q = tableSearch.text.trim().toLowerCase()
                        return q === "" ? all : all.filter(t => t.toLowerCase().indexOf(q) !== -1)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: 14
                        Layout.bottomMargin: 6
                        Text {
                            Layout.fillWidth: true
                            text: qsTr("TABLES & VIEWS")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                            font.letterSpacing: 0.6
                        }
                        Text {
                            text: parent.parent.filteredTables.length + (sessionObj && tableSearch.text ? "/" + sessionObj.tables.length : "")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                        }
                    }
                    // Table filter.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 6
                        implicitHeight: 30
                        radius: Theme.radius
                        color: Theme.surface
                        border.color: tableSearch.activeFocus ? Theme.accent : Theme.border
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 9; anchors.rightMargin: 6
                            spacing: 6
                            Icon { name: "search"; size: 13; color: Theme.textFaint }
                            TextField {
                                id: tableSearch
                                Layout.fillWidth: true
                                padding: 0
                                background: null
                                color: Theme.text
                                font.pixelSize: Theme.fontSm
                                placeholderText: qsTr("Filter tables")
                                placeholderTextColor: Theme.textFaint
                            }
                            Icon {
                                name: "x"; size: 11; color: Theme.textFaint
                                visible: tableSearch.text !== ""
                                TapHandler { onTapped: tableSearch.clear() }
                            }
                        }
                    }
                    ListView {
                        id: tablesList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: parent.filteredTables
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}
                        property int hoveredIndex: -1
                        HoverHandler { onHoveredChanged: if (!hovered) tablesList.hoveredIndex = -1 }
                        delegate: ItemDelegate {
                            id: tbd
                            required property int index
                            required property string modelData
                            width: tablesList.width
                            height: 30
                            HoverHandler {
                                onHoveredChanged: {
                                    if (hovered) tablesList.hoveredIndex = tbd.index
                                    else if (tablesList.hoveredIndex === tbd.index) tablesList.hoveredIndex = -1
                                }
                            }
                            background: Rectangle {
                                color: tablesList.hoveredIndex === tbd.index ? Theme.hover : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.fast } }
                            }
                            contentItem: RowLayout {
                                spacing: 8
                                Icon { Layout.leftMargin: 14; name: "database"; size: 14; color: Theme.sqlTag; opacity: 0.85 }
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
                    Layout.preferredHeight: page.editorHeight
                    color: Theme.surface
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
                            SqlHighlighter {
                                document: editor.textDocument
                                keywordColor: Theme.sqlKeyword
                                functionColor: Theme.sqlFunction
                                stringColor: Theme.sqlString
                                numberColor: Theme.sqlNumber
                                commentColor: Theme.sqlComment
                                identifierColor: Theme.sqlIdentifier
                                operatorColor: Theme.sqlOperator
                            }
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

                        // Save the current query (or selection) to this server.
                        GhostButton {
                            id: saveBtn
                            text: qsTr("Save")
                            iconName: "bookmark"
                            implicitHeight: 30
                            leftPadding: 12; rightPadding: 14
                            enabled: page.sqlToSave.trim() !== "" && page.serverKey !== ""
                            opacity: enabled ? 1 : 0.5
                            onClicked: {
                                saveNameField.text = page.summarizeQuery(page.sqlToSave)
                                savePop.open(); saveNameField.selectAll(); saveNameField.forceActiveFocus()
                            }

                            Popup {
                                id: savePop
                                y: -implicitHeight - 6
                                // Right-align to the button so the 320px card opens
                                // leftward and never spills past the window edge.
                                x: saveBtn.width - width
                                width: 320
                                padding: 12
                                background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                                function commit() {
                                    if (page.saveQuery(saveNameField.text)) savePop.close()
                                }
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text {
                                        text: qsTr("Save query")
                                        color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: editor && editor.selectedText.length > 0
                                              ? qsTr("Saving the selected text")
                                              : qsTr("Saving the whole editor")
                                        color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        implicitHeight: 34
                                        radius: Theme.radius
                                        color: Theme.surface
                                        border.color: saveNameField.activeFocus ? Theme.accent : Theme.border
                                        TextField {
                                            id: saveNameField
                                            anchors.fill: parent
                                            anchors.leftMargin: 10; anchors.rightMargin: 10
                                            padding: 0; background: null
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: Theme.text; font.pixelSize: Theme.fontSm
                                            placeholderText: qsTr("Name this query…")
                                            placeholderTextColor: Theme.textFaint
                                            onAccepted: savePop.commit()
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Item { Layout.fillWidth: true }
                                        GhostButton { text: qsTr("Cancel"); onClicked: savePop.close() }
                                        PrimaryButton { text: qsTr("Save"); onClicked: savePop.commit() }
                                    }
                                }
                            }
                        }

                        // Browse and recall saved queries for this server.
                        AbstractButton {
                            id: savedBtn
                            implicitHeight: 30
                            implicitWidth: savedRow.implicitWidth + 22
                            hoverEnabled: true
                            focusPolicy: Qt.NoFocus
                            onClicked: { page.refreshSaved(); savedPop.open() }
                            background: Rectangle {
                                radius: Theme.radius
                                color: savedBtn.hovered || savedPop.visible ? Theme.surface3 : Theme.surface2
                                border.color: savedPop.visible ? Theme.accent : (savedBtn.hovered ? Theme.borderStrong : Theme.border)
                                Behavior on color { ColorAnimation { duration: Theme.fast } }
                            }
                            contentItem: Row {
                                id: savedRow
                                spacing: 6
                                leftPadding: 12; rightPadding: 10
                                Icon { name: "bookmark"; size: 13; color: Theme.text
                                       anchors.verticalCenter: parent.verticalCenter }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: qsTr("Saved")
                                    color: Theme.text; font.pixelSize: Theme.fontSm; font.weight: Font.Medium
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: page.savedQueries.length > 0
                                    implicitWidth: Math.max(cnt.implicitWidth + 10, 18); implicitHeight: 17
                                    radius: 8
                                    color: Theme.surface3
                                    Text {
                                        id: cnt; anchors.centerIn: parent
                                        text: page.savedQueries.length
                                        color: Theme.textDim; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                                    }
                                }
                                Icon { name: "chevron"; size: 10; color: Theme.textFaint; rotation: 270
                                       anchors.verticalCenter: parent.verticalCenter }
                            }

                            Popup {
                                id: savedPop
                                y: -height - 6
                                x: savedBtn.width - width
                                width: 420
                                implicitHeight: Math.min(libCol.implicitHeight + 16, 460)
                                padding: 8
                                onClosed: libSearch.clear()
                                background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }

                                readonly property var items: {
                                    const all = page.savedQueries
                                    const q = libSearch.text.trim().toLowerCase()
                                    if (q === "") return all
                                    return all.filter(x => (x.name || "").toLowerCase().indexOf(q) !== -1
                                                         || (x.sql || "").toLowerCase().indexOf(q) !== -1)
                                }

                                ColumnLayout {
                                    id: libCol
                                    width: parent.width
                                    spacing: 8

                                    // Header.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 4; Layout.rightMargin: 4; Layout.topMargin: 2
                                        spacing: 8
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text {
                                                text: qsTr("Saved queries")
                                                color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: page.serverKey
                                                color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                                font.family: Theme.monoFamily; elide: Text.ElideMiddle
                                            }
                                        }
                                        Text {
                                            text: qsTr("%1 saved").arg(page.savedQueries.length)
                                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                        }
                                    }

                                    // Search (only worth showing past a few).
                                    Rectangle {
                                        Layout.fillWidth: true
                                        visible: page.savedQueries.length > 4
                                        implicitHeight: 30
                                        radius: Theme.radius
                                        color: Theme.surface
                                        border.color: libSearch.activeFocus ? Theme.accent : Theme.border
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 8; spacing: 6
                                            Icon { name: "search"; size: 12; color: Theme.textFaint }
                                            TextField {
                                                id: libSearch
                                                Layout.fillWidth: true; padding: 0; background: null
                                                color: Theme.text; font.pixelSize: Theme.fontSm
                                                placeholderText: qsTr("Search saved queries"); placeholderTextColor: Theme.textFaint
                                            }
                                        }
                                    }

                                    // Empty state.
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.margins: 8
                                        spacing: 4
                                        visible: page.savedQueries.length === 0
                                        Text {
                                            text: qsTr("No saved queries yet")
                                            color: Theme.textDim; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: qsTr("Write a query, then press Save to keep it here for this server.")
                                            color: Theme.textFaint; font.pixelSize: Theme.fontXs; wrapMode: Text.WordWrap
                                        }
                                    }

                                    // List.
                                    ListView {
                                        id: savedList
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: Math.min(contentHeight, 340)
                                        visible: page.savedQueries.length > 0
                                        clip: true
                                        model: savedPop.items
                                        boundsBehavior: Flickable.StopAtBounds
                                        ScrollBar.vertical: ScrollBar {}
                                        spacing: 2
                                        property int hoveredIndex: -1
                                        HoverHandler { onHoveredChanged: if (!hovered) savedList.hoveredIndex = -1 }
                                        delegate: ItemDelegate {
                                            id: sq
                                            required property int index
                                            required property var modelData
                                            width: savedList.width
                                            height: 50
                                            readonly property bool hov: savedList.hoveredIndex === sq.index
                                            HoverHandler {
                                                onHoveredChanged: {
                                                    if (hovered) savedList.hoveredIndex = sq.index
                                                    else if (savedList.hoveredIndex === sq.index) savedList.hoveredIndex = -1
                                                }
                                            }
                                            onClicked: { page.loadQuery(sq.modelData.sql); savedPop.close() }
                                            background: Rectangle {
                                                radius: Theme.radiusSm
                                                color: sq.hov ? Theme.hover : "transparent"
                                                Behavior on color { ColorAnimation { duration: Theme.fast } }
                                            }
                                            contentItem: RowLayout {
                                                spacing: 6
                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    Layout.leftMargin: 8
                                                    spacing: 2
                                                    RowLayout {
                                                        Layout.fillWidth: true
                                                        spacing: 8
                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: sq.modelData.name
                                                            color: Theme.text; font.pixelSize: Theme.fontSm
                                                            font.weight: Font.DemiBold; elide: Text.ElideRight
                                                        }
                                                        Text {
                                                            visible: !sq.hov
                                                            text: page.fmtAgo(sq.modelData.updated)
                                                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                                        }
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: (sq.modelData.sql || "").replace(/\s+/g, " ").trim()
                                                        color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                                        font.family: Theme.monoFamily; elide: Text.ElideRight; maximumLineCount: 1
                                                    }
                                                }
                                                // Hover actions: Run, Delete.
                                                Row {
                                                    Layout.rightMargin: 6
                                                    spacing: 2
                                                    visible: sq.hov
                                                    AbstractButton {
                                                        width: 26; height: 26
                                                        hoverEnabled: true
                                                        ToolTip.visible: hovered; ToolTip.text: qsTr("Load & run"); ToolTip.delay: 350
                                                        onClicked: { page.runSaved(sq.modelData.sql); savedPop.close() }
                                                        background: Rectangle { radius: Theme.radiusSm; color: parent.hovered ? Theme.accentSoft : "transparent" }
                                                        contentItem: Icon { name: "zap"; size: 13
                                                            color: parent.hovered ? Theme.accent : Theme.textDim; anchors.centerIn: parent }
                                                    }
                                                    AbstractButton {
                                                        width: 26; height: 26
                                                        hoverEnabled: true
                                                        ToolTip.visible: hovered; ToolTip.text: qsTr("Delete"); ToolTip.delay: 350
                                                        onClicked: QueryStore.remove(sq.modelData.id)
                                                        background: Rectangle { radius: Theme.radiusSm; color: parent.hovered ? Theme.dangerSoft : "transparent" }
                                                        contentItem: Icon { name: "trash"; size: 13
                                                            color: parent.hovered ? Theme.danger : Theme.textFaint; anchors.centerIn: parent }
                                                    }
                                                }
                                            }
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            visible: savedList.count === 0 && page.savedQueries.length > 0
                                            text: qsTr("No matches")
                                            color: Theme.textFaint; font.pixelSize: Theme.fontSm
                                        }
                                    }
                                }
                            }
                        }

                        PrimaryButton {
                            text: page.st === SqlSession.Executing ? qsTr("Running…")
                                : page.st === SqlSession.Connecting ? qsTr("Resuming…")
                                : page.paused ? qsTr("Resume & run") : qsTr("Run")
                            iconName: "arrow-right"
                            implicitHeight: 30
                            leftPadding: 14; rightPadding: 14
                            enabled: !page.busy
                            onClicked: page.run()
                        }
                    }
                }

                // Draggable divider — resize the editor vs the results area.
                Item {
                    id: splitter
                    Layout.fillWidth: true
                    Layout.preferredHeight: 11
                    readonly property bool active: splitHover.hovered || splitDrag.pressed
                    // The divider line, a touch bolder on the active side.
                    Rectangle {
                        anchors.top: parent.top; width: parent.width; height: 1
                        color: splitter.active ? Theme.borderStrong : Theme.border
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom; width: parent.width; height: 1
                        color: Theme.border; opacity: 0.6
                    }
                    // Always-visible grab handle: a pill with three dots.
                    Rectangle {
                        anchors.centerIn: parent
                        width: 46; height: 11; radius: 5.5
                        color: splitter.active ? Theme.accentSoft : Theme.surface2
                        border.color: splitter.active ? Theme.accent : Theme.borderStrong
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                        Row {
                            anchors.centerIn: parent
                            spacing: 3
                            Repeater {
                                model: 3
                                delegate: Rectangle {
                                    width: 3; height: 3; radius: 1.5
                                    color: splitter.active ? Theme.accent : Theme.textFaint
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                            }
                        }
                    }
                    HoverHandler { id: splitHover; cursorShape: Qt.SplitVCursor }
                    MouseArea {
                        id: splitDrag
                        anchors.fill: parent
                        anchors.topMargin: -3; anchors.bottomMargin: -3
                        cursorShape: Qt.SplitVCursor
                        property real pressY: 0
                        property real pressH: 0
                        onPressed: (m) => { pressY = mapToItem(page, m.x, m.y).y; pressH = page.editorHeight }
                        onPositionChanged: (m) => {
                            const dy = mapToItem(page, m.x, m.y).y - pressY
                            page.editorHeight = Math.max(90, Math.min(page.height - 220, pressH + dy))
                        }
                    }
                }

                // Results — each result grid carries its own search bar; several
                // stack top-to-bottom for a multi-statement batch.
                Item {
                    id: resultsArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    readonly property var res: sessionObj ? sessionObj.result : null
                    readonly property var models: sessionObj ? sessionObj.resultModels : []
                    readonly property int count: models.length
                    readonly property bool hasGrid: count > 0
                    // Server-side record search only for a lone single-table read.
                    readonly property string serverTable: sessionObj ? sessionObj.statsTable : ""
                    property var activeGrid: null       // grid the keyboard copy acts on

                    function exec(sql) { editor.text = sql; if (sessionObj) sessionObj.execute(sql) }

                    // Single result set — one full-height grid with its own bar.
                    ResultGrid {
                        id: soloGrid
                        anchors.fill: parent
                        visible: resultsArea.count === 1
                        model: resultsArea.res
                        ordinal: 0
                        stacked: false
                        serverTable: resultsArea.serverTable
                        onToast: (m, k) => page.toast(m, k)
                        onServerSearch: (sql) => resultsArea.exec(sql)
                        onActivated: resultsArea.activeGrid = soloGrid
                    }

                    // Multiple result sets — stacked, each with its own bar.
                    ListView {
                        anchors.fill: parent
                        visible: resultsArea.count > 1
                        clip: true
                        model: resultsArea.count > 1 ? resultsArea.models : []
                        spacing: 0
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}
                        delegate: ResultGrid {
                            id: stackGrid
                            required property int index
                            required property var modelData
                            width: ListView.view.width
                            height: {
                                const rows = modelData && modelData.rows !== undefined ? modelData.rows : 0
                                const bodyRows = Math.min(Math.max(rows, 1), 12)
                                return 28 + 44 + 30 + bodyRows * 28 + 1  // header + bar + col-head + rows
                            }
                            model: modelData
                            ordinal: index
                            stacked: true
                            serverTable: ""   // per-set in-memory filter
                            onToast: (m, k) => page.toast(m, k)
                            onActivated: resultsArea.activeGrid = stackGrid
                        }
                    }

                    // Empty / message / error state.
                    Column {
                        anchors.centerIn: parent
                        spacing: 10
                        visible: !resultsArea.hasGrid
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
                        // Table stats (total rows / size) stream in from the
                        // background once the query targets a single table.
                        Text {
                            visible: sessionObj && sessionObj.statsTable !== ""
                                     && sessionObj.tableRowCount >= 0
                            text: {
                                if (!sessionObj || sessionObj.tableRowCount < 0) return ""
                                let s = Number(sessionObj.tableRowCount).toLocaleString(Qt.locale(), 'f', 0) + qsTr(" rows")
                                const sz = page.fmtSize(sessionObj.tableSizeKb)
                                if (sz) s += "  ·  " + sz
                                return sessionObj.statsTable + ":  " + s
                            }
                            color: Theme.textDim; font.pixelSize: Theme.fontXs
                        }
                        Rectangle {
                            visible: sessionObj && sessionObj.statsTable !== "" && sessionObj.tableRowCount >= 0
                            width: 1; height: 12; color: Theme.border
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: sessionObj && sessionObj.result.columns.length > 0
                            text: sessionObj ? sessionObj.result.rows + qsTr(" shown · ") + sessionObj.elapsedMs + " ms" : ""
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
    // Copy the selected cell; Shift adds the whole row. Only when a cell is
    // selected, so the editor keeps normal copy while it has focus.
    Shortcut { sequences: [StandardKey.Copy]; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copySel() }
    Shortcut { sequence: "Ctrl+Shift+C"; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copyRow() }
    Shortcut { sequence: "Meta+Shift+C"; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copyRow() }
}
