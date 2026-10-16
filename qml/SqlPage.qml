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

                Icon { name: "database"; size: 15; color: Theme.sqlTag }
                // Database context switcher with search.
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
                                delegate: ItemDelegate {
                                    required property string modelData
                                    width: dbList.width
                                    height: 30
                                    readonly property bool current: sessionObj && sessionObj.currentDatabase === modelData
                                    contentItem: RowLayout {
                                        spacing: 6
                                        Text {
                                            Layout.fillWidth: true; Layout.leftMargin: 6
                                            text: modelData
                                            color: current ? Theme.sqlTag : Theme.text
                                            font.pixelSize: Theme.fontSm
                                            font.weight: current ? Font.DemiBold : Font.Normal
                                            elide: Text.ElideRight
                                        }
                                    }
                                    background: Rectangle { radius: Theme.radiusSm; color: hovered ? Theme.surface3 : "transparent" }
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
                    id: resultsArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    readonly property var res: sessionObj ? sessionObj.result : null
                    readonly property bool hasGrid: res && res.columns.length > 0
                    property int selRow: -1
                    property int selCol: -1
                    // Record search: only possible when the grid came from one table.
                    readonly property string searchTable: sessionObj ? sessionObj.statsTable : ""
                    readonly property bool canSearch: hasGrid && searchTable !== ""
                    property string searchCol: ""

                    // Runs a server-side search for rows where `searchCol` matches.
                    function findRecords(exact) {
                        if (!canSearch || searchCol === "") return
                        const col = "[" + searchCol.replace(/]/g, "]]") + "]"
                        const raw = recSearch.text
                        if (raw.trim() === "") { sessionObj.execute("SELECT TOP 500 * FROM " + searchTable); return }
                        let sql
                        if (exact) {
                            const v = raw.replace(/'/g, "''")
                            sql = "SELECT TOP 500 * FROM " + searchTable
                                + " WHERE CAST(" + col + " AS NVARCHAR(MAX)) = '" + v + "'"
                        } else {
                            let pat = raw.replace(/[\\%_\[]/g, m => "\\" + m).replace(/'/g, "''")
                            sql = "SELECT TOP 500 * FROM " + searchTable
                                + " WHERE CAST(" + col + " AS NVARCHAR(MAX)) LIKE '%" + pat + "%' ESCAPE '\\'"
                        }
                        editor.text = sql
                        sessionObj.execute(sql)
                    }

                    function copySel() {
                        if (!res || selRow < 0 || selCol < 0) return
                        Clipboard.copy(res.cellText(selRow, selCol))
                        page.toast(qsTr("Cell copied"), "info")
                    }
                    function copyRow() {
                        if (!res || selRow < 0) return
                        Clipboard.copy(res.rowText(selRow))
                        page.toast(qsTr("Row copied"), "info")
                    }
                    function copyRowJson() {
                        if (!res || selRow < 0) return
                        const cols = res.columns, o = {}
                        for (let c = 0; c < cols.length; c++)
                            o[cols[c]] = res.cellText(selRow, c)
                        Clipboard.copy(JSON.stringify(o, null, 2))
                        page.toast(qsTr("Row copied as JSON"), "info")
                    }
                    function copyColumn() {
                        if (!res || selCol < 0) return
                        const out = []
                        for (let r = 0; r < res.rows; r++)
                            out.push(res.cellText(r, selCol))
                        Clipboard.copy(out.join("\n"))
                        page.toast(qsTr("Column copied (%1 values)").arg(res.rows), "info")
                    }
                    function copyInsert() {
                        if (!res || selRow < 0) return
                        const cols = res.columns
                        const tbl = sessionObj && sessionObj.statsTable ? sessionObj.statsTable : "table"
                        const vals = []
                        for (let c = 0; c < cols.length; c++) {
                            const v = res.cellText(selRow, c)
                            if (v === "NULL") vals.push("NULL")
                            else if (/^-?\d+(\.\d+)?$/.test(v)) vals.push(v)
                            else vals.push("'" + v.replace(/'/g, "''") + "'")
                        }
                        Clipboard.copy("INSERT INTO " + tbl + " (" + cols.join(", ") + ")\nVALUES (" + vals.join(", ") + ");")
                        page.toast(qsTr("Copied as INSERT"), "info")
                    }

                    // Right-click menu for the selected cell/row.
                    Menu {
                        id: cellMenu
                        padding: 6
                        background: Rectangle { implicitWidth: 210; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                        enter: Transition { ParallelAnimation {
                            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                            NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
                        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
                        delegate: MenuItem {
                            id: cmi
                            implicitHeight: 30
                            contentItem: Text {
                                leftPadding: 6; text: cmi.text; color: Theme.text
                                font.pixelSize: Theme.fontMd; verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle { radius: Theme.radiusSm; color: cmi.highlighted ? Theme.surface3 : "transparent" }
                        }
                        Action { text: qsTr("Copy cell"); onTriggered: resultsArea.copySel() }
                        Action { text: qsTr("Copy row"); onTriggered: resultsArea.copyRow() }
                        Action { text: qsTr("Copy row as JSON"); onTriggered: resultsArea.copyRowJson() }
                        Action { text: qsTr("Copy as INSERT"); onTriggered: resultsArea.copyInsert() }
                        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
                        Action { text: qsTr("Copy column"); onTriggered: resultsArea.copyColumn() }
                    }

                    Connections {
                        target: resultsArea.res
                        function onResetted() {
                            resultsArea.selRow = -1; resultsArea.selCol = -1
                            // Default the search column to the first one if unset/stale.
                            const cols = resultsArea.res ? resultsArea.res.columns : []
                            if (cols.indexOf(resultsArea.searchCol) === -1)
                                resultsArea.searchCol = cols.length ? cols[0] : ""
                            table.forceLayout()
                        }
                        function onSortChanged() { table.forceLayout() }
                    }

                    // Record search bar — find rows by a column value (server-side).
                    Rectangle {
                        id: searchBar
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: 40
                        visible: resultsArea.canSearch
                        color: Theme.surface
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Icon { name: "search"; size: 14; color: Theme.textFaint }
                            Text {
                                text: qsTr("Find in")
                                color: Theme.textDim; font.pixelSize: Theme.fontSm
                            }

                            // Column picker.
                            Item {
                                Layout.preferredWidth: 160
                                implicitHeight: 28
                                AbstractButton {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    focusPolicy: Qt.NoFocus
                                    onClicked: { colPop.open(); colSearch.forceActiveFocus() }
                                    background: Rectangle {
                                        radius: Theme.radius
                                        color: parent.hovered ? Theme.surface2 : Theme.bg
                                        border.color: colPop.visible ? Theme.accent : Theme.border
                                    }
                                    contentItem: RowLayout {
                                        spacing: 4
                                        Text {
                                            Layout.fillWidth: true; Layout.leftMargin: 10
                                            text: resultsArea.searchCol || qsTr("column")
                                            color: Theme.text; font.pixelSize: Theme.fontSm
                                            font.family: Theme.monoFamily
                                            verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                        }
                                        Icon { Layout.rightMargin: 8; name: "chevron"; size: 10; color: Theme.textFaint; rotation: 90 }
                                    }
                                }
                                Popup {
                                    id: colPop
                                    y: parent.height + 4
                                    width: 220
                                    implicitHeight: Math.min(colColumn.implicitHeight + 12, 320)
                                    padding: 6
                                    onClosed: colSearch.clear()
                                    background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                                    readonly property var cols: {
                                        const all = resultsArea.res ? resultsArea.res.columns : []
                                        const q = colSearch.text.trim().toLowerCase()
                                        return q === "" ? all : all.filter(c => c.toLowerCase().indexOf(q) !== -1)
                                    }
                                    contentItem: ColumnLayout {
                                        id: colColumn
                                        spacing: 6
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 28; radius: Theme.radius
                                            color: Theme.surface; border.color: colSearch.activeFocus ? Theme.accent : Theme.border
                                            RowLayout {
                                                anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 8; spacing: 6
                                                Icon { name: "search"; size: 12; color: Theme.textFaint }
                                                TextField {
                                                    id: colSearch
                                                    Layout.fillWidth: true; padding: 0; background: null
                                                    color: Theme.text; font.pixelSize: Theme.fontSm
                                                    placeholderText: qsTr("Search columns"); placeholderTextColor: Theme.textFaint
                                                }
                                            }
                                        }
                                        ListView {
                                            id: colList
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: Math.min(contentHeight, 260)
                                            clip: true
                                            model: colPop.cols
                                            boundsBehavior: Flickable.StopAtBounds
                                            ScrollBar.vertical: ScrollBar {}
                                            delegate: ItemDelegate {
                                                required property string modelData
                                                width: colList.width; height: 28
                                                readonly property bool current: resultsArea.searchCol === modelData
                                                contentItem: Text {
                                                    leftPadding: 6; text: modelData
                                                    color: current ? Theme.accent : Theme.text
                                                    font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
                                                    verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                                }
                                                background: Rectangle { radius: Theme.radiusSm; color: hovered ? Theme.surface3 : "transparent" }
                                                onClicked: { resultsArea.searchCol = modelData; colPop.close() }
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 28
                                radius: Theme.radius
                                color: Theme.bg
                                border.color: recSearch.activeFocus ? Theme.accent : Theme.border
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 6
                                    TextField {
                                        id: recSearch
                                        Layout.fillWidth: true; padding: 0; background: null
                                        color: Theme.text; font.pixelSize: Theme.fontSm
                                        placeholderText: qsTr("contains value…"); placeholderTextColor: Theme.textFaint
                                        onAccepted: resultsArea.findRecords(false)
                                    }
                                    Icon {
                                        name: "x"; size: 11; color: Theme.textFaint
                                        visible: recSearch.text !== ""
                                        TapHandler { onTapped: { recSearch.clear(); recSearch.forceActiveFocus() } }
                                    }
                                }
                            }
                            GhostButton { text: qsTr("Exact"); onClicked: resultsArea.findRecords(true) }
                            PrimaryButton { text: qsTr("Find"); iconName: "search"; onClicked: resultsArea.findRecords(false) }
                        }
                    }

                    GridLayout {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                  top: searchBar.visible ? searchBar.bottom : parent.top }
                        columns: 2
                        rowSpacing: 0
                        columnSpacing: 0
                        visible: resultsArea.hasGrid

                        // Top-left corner filler, aligned with the two headers.
                        Rectangle {
                            Layout.preferredWidth: vhv.width
                            Layout.preferredHeight: 30
                            color: Theme.surface2
                            border.color: Theme.border
                        }
                        HorizontalHeaderView {
                            id: hhv
                            Layout.fillWidth: true
                            syncView: table
                            clip: true
                            delegate: Rectangle {
                                id: hcell
                                required property int index
                                required property string display
                                implicitHeight: 30
                                readonly property bool sorted: resultsArea.res && resultsArea.res.sortColumn === index
                                color: hhvHover.hovered ? Theme.surface3 : Theme.surface2
                                border.color: Theme.border
                                Behavior on color { ColorAnimation { duration: Theme.fast } }
                                HoverHandler { id: hhvHover }
                                TapHandler { onTapped: if (resultsArea.res) resultsArea.res.sortByColumn(hcell.index) }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 6
                                    spacing: 4
                                    Text {
                                        Layout.fillWidth: true
                                        verticalAlignment: Text.AlignVCenter
                                        text: hcell.display
                                        color: hcell.sorted ? Theme.text : Theme.textDim
                                        font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        visible: hcell.sorted
                                        text: resultsArea.res && resultsArea.res.sortAscending ? "▲" : "▼"
                                        color: Theme.accent; font.pixelSize: 8
                                    }
                                }
                            }
                        }
                        // Row-number gutter.
                        VerticalHeaderView {
                            id: vhv
                            Layout.fillHeight: true
                            Layout.preferredWidth: 52
                            syncView: table
                            clip: true
                            delegate: Rectangle {
                                required property int index
                                implicitWidth: 52
                                color: Theme.surface2
                                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
                                Text {
                                    anchors.fill: parent; anchors.rightMargin: 8
                                    horizontalAlignment: Text.AlignRight; verticalAlignment: Text.AlignVCenter
                                    text: index + 1
                                    color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                                }
                            }
                        }
                        TableView {
                            id: table
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: resultsArea.res
                            boundsBehavior: Flickable.StopAtBounds
                            columnWidthProvider: function (c) {
                                const w = resultsArea.res ? resultsArea.res.columnWidths[c] : 0
                                return w ? w : 160
                            }
                            rowHeightProvider: function (r) { return 28 }
                            ScrollBar.vertical: ScrollBar {}
                            ScrollBar.horizontal: ScrollBar {}
                            delegate: Rectangle {
                                id: cell
                                required property int row
                                required property int column
                                required property string display
                                required property bool isNull
                                readonly property bool selected: resultsArea.selRow === row && resultsArea.selCol === column
                                implicitWidth: 160
                                implicitHeight: 28
                                color: selected ? Theme.accentSoft : (row % 2 ? Theme.bg : Theme.surface)
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border; opacity: 0.5 }
                                Rectangle { visible: cell.selected; anchors.fill: parent; color: "transparent"; border.color: Theme.accent; border.width: 1 }
                                TapHandler {
                                    onTapped: { resultsArea.selRow = cell.row; resultsArea.selCol = cell.column }
                                    onDoubleTapped: { resultsArea.selRow = cell.row; resultsArea.selCol = cell.column; resultsArea.copySel() }
                                }
                                TapHandler {
                                    acceptedButtons: Qt.RightButton
                                    onTapped: {
                                        resultsArea.selRow = cell.row
                                        resultsArea.selCol = cell.column
                                        cellMenu.popup()
                                    }
                                }
                                Text {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                                    verticalAlignment: Text.AlignVCenter
                                    text: cell.isNull ? "NULL" : cell.display
                                    color: cell.isNull ? Theme.textFaint : Theme.text
                                    font.italic: cell.isNull === true
                                    font.family: Theme.monoFamily; font.pixelSize: Theme.fontSm
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }

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
    Shortcut { sequences: [StandardKey.Copy]; enabled: page.active && resultsArea.selRow >= 0; onActivated: resultsArea.copySel() }
    Shortcut { sequence: "Ctrl+Shift+C"; enabled: page.active && resultsArea.selRow >= 0; onActivated: resultsArea.copyRow() }
    Shortcut { sequence: "Meta+Shift+C"; enabled: page.active && resultsArea.selRow >= 0; onActivated: resultsArea.copyRow() }
}
