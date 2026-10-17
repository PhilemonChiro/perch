import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// One result set: an optional section header, its own compact search/filter bar,
// and the data grid (row-number gutter, click-to-sort headers, cell selection,
// copy menu). Several stack vertically for a multi-statement batch; a lone one
// fills the results area. When `serverTable` is set the search runs server-side
// over that whole table; otherwise it filters the fetched rows in memory.
Item {
    id: rg

    property var model                  // SqlResultModel
    property int ordinal: 0             // 0-based position, for the header label
    property bool stacked: false        // show the section header
    property string serverTable: ""     // non-empty → server-side search

    signal toast(string message, string kind)
    signal serverSearch(string sql)     // host executes this SQL
    signal activated()                  // a cell here was selected

    readonly property bool hasGrid: model && model.columns.length > 0
    readonly property bool serverMode: serverTable !== ""
    property int selRow: -1
    property int selCol: -1
    property int hoverRow: -1
    property string searchCol: ""
    property bool exactMode: false
    readonly property int searchColIndex: model ? model.columns.indexOf(searchCol) : -1

    function findRecords(exact) {
        if (!hasGrid) return
        const raw = valueField.text
        if (!serverMode) { if (model) model.filter(searchColIndex, raw.trim(), exact); return }
        if (searchCol === "") return
        const col = "[" + searchCol.replace(/]/g, "]]") + "]"
        if (raw.trim() === "") { rg.serverSearch("SELECT TOP 500 * FROM " + serverTable); return }
        let sql
        if (exact) {
            const v = raw.replace(/'/g, "''")
            sql = "SELECT TOP 500 * FROM " + serverTable
                + " WHERE CAST(" + col + " AS NVARCHAR(MAX)) = '" + v + "'"
        } else {
            let pat = raw.replace(/[\\%_\[]/g, m => "\\" + m).replace(/'/g, "''")
            sql = "SELECT TOP 500 * FROM " + serverTable
                + " WHERE CAST(" + col + " AS NVARCHAR(MAX)) LIKE '%" + pat + "%' ESCAPE '\\'"
        }
        rg.serverSearch(sql)
    }

    function copySel() {
        if (!model || selRow < 0 || selCol < 0) return
        Clipboard.copy(model.cellText(selRow, selCol)); rg.toast(qsTr("Cell copied"), "info")
    }
    function copyRow() {
        if (!model || selRow < 0) return
        Clipboard.copy(model.rowText(selRow)); rg.toast(qsTr("Row copied"), "info")
    }
    function copyRowJson() {
        if (!model || selRow < 0) return
        const cols = model.columns, o = {}
        for (let c = 0; c < cols.length; c++) o[cols[c]] = model.cellText(selRow, c)
        Clipboard.copy(JSON.stringify(o, null, 2)); rg.toast(qsTr("Row copied as JSON"), "info")
    }
    function copyColumn() {
        if (!model || selCol < 0) return
        const out = []
        for (let r = 0; r < model.rows; r++) out.push(model.cellText(r, selCol))
        Clipboard.copy(out.join("\n")); rg.toast(qsTr("Column copied (%1 values)").arg(model.rows), "info")
    }
    function copyInsert() {
        if (!model || selRow < 0) return
        const cols = model.columns
        const tbl = serverTable !== "" ? serverTable : "table"
        const vals = []
        for (let c = 0; c < cols.length; c++) {
            const v = model.cellText(selRow, c)
            if (v === "NULL") vals.push("NULL")
            else if (/^-?\d+(\.\d+)?$/.test(v)) vals.push(v)
            else vals.push("'" + v.replace(/'/g, "''") + "'")
        }
        Clipboard.copy("INSERT INTO " + tbl + " (" + cols.join(", ") + ")\nVALUES (" + vals.join(", ") + ");")
        rg.toast(qsTr("Copied as INSERT"), "info")
    }

    Connections {
        target: rg.model
        function onResetted() {
            rg.selRow = -1; rg.selCol = -1
            const cols = rg.model ? rg.model.columns : []
            if (cols.indexOf(rg.searchCol) === -1)
                rg.searchCol = cols.length ? cols[0] : ""
            table.forceLayout()
        }
        function onSortChanged() { table.forceLayout() }
        function onFilterChanged() { table.forceLayout() }
    }

    Menu {
        id: cellMenu
        padding: 6
        background: Rectangle { implicitWidth: 210; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
        delegate: MenuItem {
            id: cmi
            implicitHeight: 30
            contentItem: Text {
                leftPadding: 6; text: cmi.text; color: Theme.text
                font.pixelSize: Theme.fontMd; verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle { radius: Theme.radiusSm; color: cmi.highlighted ? Theme.surface3 : "transparent" }
        }
        Action { text: qsTr("Copy cell"); onTriggered: rg.copySel() }
        Action { text: qsTr("Copy row"); onTriggered: rg.copyRow() }
        Action { text: qsTr("Copy row as JSON"); onTriggered: rg.copyRowJson() }
        Action { text: qsTr("Copy as INSERT"); onTriggered: rg.copyInsert() }
        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
        Action { text: qsTr("Copy column"); onTriggered: rg.copyColumn() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Section header (stacked view only) — result label + row count.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            visible: rg.stacked
            color: Theme.surface2
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                Rectangle { width: 6; height: 6; radius: 3; color: Theme.sqlTag }
                Text {
                    text: qsTr("Result %1").arg(rg.ordinal + 1)
                    color: Theme.text; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: rg.model ? (rg.model.filtered
                            ? qsTr("%1 of %2 rows").arg(rg.model.rows).arg(rg.model.totalRows)
                            : qsTr("%1 rows").arg(rg.model.rows)) : ""
                    color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                }
            }
        }

        // Search / filter bar — one per result.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            visible: rg.hasGrid
            color: Theme.surface
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8

                Icon { name: "search"; size: 13; color: Theme.textFaint }
                Text {
                    text: rg.serverMode ? qsTr("Find in") : qsTr("Filter")
                    color: Theme.textFaint; font.pixelSize: Theme.fontSm
                }
                Text {
                    visible: rg.serverMode
                    text: rg.serverTable
                    color: Theme.sqlTag; font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold; font.family: Theme.monoFamily
                    elide: Text.ElideMiddle; Layout.maximumWidth: 160
                }

                // Unified control: [ column ▾ │ value … × ] — capped, not full-width.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.maximumWidth: 430
                    implicitHeight: 30
                    radius: Theme.radius
                    color: Theme.bg
                    border.color: (valueField.activeFocus || colPop.visible) ? Theme.accent : Theme.border
                    Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                    RowLayout {
                        anchors.fill: parent; spacing: 0
                        Item {
                            id: colPick
                            Layout.preferredWidth: 140
                            Layout.fillHeight: true
                            AbstractButton {
                                anchors.fill: parent
                                hoverEnabled: true; focusPolicy: Qt.NoFocus
                                onClicked: { colPop.open(); colSearch.forceActiveFocus() }
                                background: Rectangle {
                                    radius: Theme.radius
                                    color: parent.hovered || colPop.visible ? Theme.surface2 : "transparent"
                                }
                                contentItem: RowLayout {
                                    spacing: 2
                                    Text {
                                        Layout.fillWidth: true; Layout.leftMargin: 12
                                        text: rg.searchCol || qsTr("any column")
                                        color: rg.searchCol ? Theme.text : Theme.textFaint
                                        font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
                                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                    }
                                    Icon { Layout.rightMargin: 9; name: "chevron"; size: 10; color: Theme.textFaint; rotation: 90 }
                                }
                            }
                            Popup {
                                id: colPop
                                y: colPick.height + 6
                                width: 210
                                implicitHeight: Math.min(colColumn.implicitHeight + 12, 320)
                                padding: 6
                                onClosed: colSearch.clear()
                                background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                                readonly property var cols: {
                                    const all = rg.model ? rg.model.columns : []
                                    const q = colSearch.text.trim().toLowerCase()
                                    const base = q === "" ? all : all.filter(c => c.toLowerCase().indexOf(q) !== -1)
                                    return rg.serverMode ? base : [""].concat(base)
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
                                            readonly property bool current: rg.searchCol === modelData
                                            contentItem: Text {
                                                leftPadding: 6
                                                text: modelData === "" ? qsTr("any column") : modelData
                                                color: current ? Theme.accent : Theme.text
                                                font.pixelSize: Theme.fontSm
                                                font.family: modelData === "" ? Theme.fontFamily : Theme.monoFamily
                                                font.italic: modelData === ""
                                                verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                            }
                                            background: Rectangle { radius: Theme.radiusSm; color: hovered ? Theme.surface3 : "transparent" }
                                            onClicked: { rg.searchCol = modelData; colPop.close() }
                                        }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            Layout.preferredWidth: 1; Layout.topMargin: 6; Layout.bottomMargin: 6
                            Layout.fillHeight: true; color: Theme.border
                        }
                        TextField {
                            id: valueField
                            Layout.fillWidth: true; Layout.leftMargin: 11
                            padding: 0; background: null
                            color: Theme.text; font.pixelSize: Theme.fontSm
                            verticalAlignment: TextInput.AlignVCenter
                            placeholderText: rg.exactMode ? qsTr("equals…") : qsTr("contains…")
                            placeholderTextColor: Theme.textFaint
                            onAccepted: rg.findRecords(rg.exactMode)
                        }
                        Icon {
                            name: "x"; size: 11; color: Theme.textFaint
                            Layout.rightMargin: 11
                            visible: valueField.text !== "" || (rg.model && rg.model.filtered)
                            TapHandler {
                                onTapped: {
                                    valueField.clear()
                                    if (!rg.serverMode && rg.model) rg.model.clearFilter()
                                    valueField.forceActiveFocus()
                                }
                            }
                        }
                    }
                }

                // "Exact match" toggle — ghost-button styling, accent when on.
                Button {
                    id: exactChip
                    text: qsTr("Exact")
                    hoverEnabled: true
                    implicitHeight: 30
                    leftPadding: 14; rightPadding: 14
                    scale: pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutBack; easing.overshoot: 2.5 } }
                    onClicked: rg.exactMode = !rg.exactMode
                    ToolTip.visible: hovered; ToolTip.delay: 450
                    ToolTip.text: rg.exactMode ? qsTr("Matching the whole value")
                                               : qsTr("Matching any part of the value")
                    background: Rectangle {
                        radius: Theme.radius
                        color: rg.exactMode ? Theme.accentSoft : (exactChip.hovered ? Theme.surface3 : Theme.surface2)
                        border.color: rg.exactMode ? Theme.accent : (exactChip.hovered ? Theme.borderStrong : Theme.border)
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                    }
                    contentItem: Text {
                        text: exactChip.text
                        color: rg.exactMode ? Theme.accent : Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMd
                        font.weight: rg.exactMode ? Font.DemiBold : Font.Medium
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                }
                // Find / Filter — the app's primary button, for a consistent look.
                PrimaryButton {
                    text: rg.serverMode ? qsTr("Find") : qsTr("Filter")
                    iconName: "search"
                    implicitHeight: 30
                    leftPadding: 14; rightPadding: 14
                    onClicked: rg.findRecords(rg.exactMode)
                }

                // Keep the controls left-grouped; the input stays capped.
                Item { Layout.fillWidth: true }
            }
        }

        // Grid.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            GridLayout {
                anchors.fill: parent
                columns: 2
                rowSpacing: 0; columnSpacing: 0
                visible: rg.hasGrid

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
                        readonly property bool sorted: rg.model && rg.model.sortColumn === index
                        color: hhvHover.hovered ? Theme.surface3 : Theme.surface2
                        border.color: Theme.border
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        HoverHandler { id: hhvHover }
                        TapHandler { onTapped: if (rg.model) rg.model.sortByColumn(hcell.index) }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 4
                            Text {
                                Layout.fillWidth: true
                                verticalAlignment: Text.AlignVCenter
                                text: hcell.display
                                color: hcell.sorted ? Theme.text : Theme.textDim
                                font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold; elide: Text.ElideRight
                            }
                            Text {
                                visible: hcell.sorted
                                text: rg.model && rg.model.sortAscending ? "▲" : "▼"
                                color: Theme.accent; font.pixelSize: 8
                            }
                        }
                    }
                }
                VerticalHeaderView {
                    id: vhv
                    Layout.fillHeight: true
                    Layout.preferredWidth: 52
                    syncView: table
                    clip: true
                    delegate: Rectangle {
                        required property int index
                        readonly property bool rowHover: rg.hoverRow === index
                        implicitWidth: 52
                        color: rowHover ? Theme.surface3 : Theme.surface2
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
                        Text {
                            anchors.fill: parent; anchors.rightMargin: 8
                            horizontalAlignment: Text.AlignRight; verticalAlignment: Text.AlignVCenter
                            text: index + 1
                            color: rowHover ? Theme.textDim : Theme.textFaint
                            font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                        }
                    }
                }
                TableView {
                    id: table
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: rg.model
                    boundsBehavior: Flickable.StopAtBounds
                    columnWidthProvider: function (c) {
                        const w = rg.model ? rg.model.columnWidths[c] : 0
                        return w ? w : 160
                    }
                    rowHeightProvider: function (r) { return 28 }
                    ScrollBar.vertical: ScrollBar {}
                    ScrollBar.horizontal: ScrollBar {}
                    HoverHandler { onHoveredChanged: if (!hovered) rg.hoverRow = -1 }
                    delegate: Rectangle {
                        id: cell
                        required property int row
                        required property int column
                        required property string display
                        required property bool isNull
                        readonly property bool selected: rg.selRow === row && rg.selCol === column
                        readonly property bool rowHover: rg.hoverRow === row
                        readonly property bool numeric: !isNull && /^-?\d{1,3}(,\d{3})*(\.\d+)?$|^-?\d+(\.\d+)?$/.test(display)
                        implicitWidth: 160
                        implicitHeight: 28
                        color: selected ? Theme.accentSoft
                             : rowHover ? Theme.surface2
                             : (row % 2 ? Theme.bg : Theme.surface)
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border; opacity: 0.5 }
                        Rectangle { visible: cell.selected; anchors.fill: parent; color: "transparent"; border.color: Theme.accent; border.width: 1 }
                        HoverHandler { onHoveredChanged: if (hovered) rg.hoverRow = cell.row }
                        TapHandler {
                            onTapped: { rg.selRow = cell.row; rg.selCol = cell.column; rg.activated() }
                            onDoubleTapped: { rg.selRow = cell.row; rg.selCol = cell.column; rg.activated(); rg.copySel() }
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: { rg.selRow = cell.row; rg.selCol = cell.column; rg.activated(); cellMenu.popup() }
                        }
                        Text {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                            horizontalAlignment: cell.numeric ? Text.AlignRight : Text.AlignLeft
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
        }
    }
}
