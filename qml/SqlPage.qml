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

    // The active query tab's editor: `editor` is its TextArea (text, selection,
    // caret), `editorView` the SqlEditor around it (undoable edits, find,
    // format). Each tab has its own instance; these follow the active tab.
    property Item editor: null
    property Item editorView: null
    // Replaces the active editor's text as one undoable step.
    function setEditorText(sql) { if (editorView) editorView.setText(sql) }
    function focusEditor() { Qt.callLater(() => { if (page.editor) page.editor.forceActiveFocus() }) }

    readonly property int st: sessionObj ? sessionObj.state : 0
    // Once we've connected at least once the database list is populated; that's
    // our gate: before it, show the password form; after, the workspace (even
    // when paused/disconnected, so the editor and results survive).
    readonly property bool everConnected: sessionObj && sessionObj.databases.length > 0
    readonly property bool live: st === SqlSession.Connected
    readonly property bool busy: st === SqlSession.Connecting || st === SqlSession.Executing
    readonly property bool paused: st === SqlSession.Paused || st === SqlSession.Disconnected

    // Connect-gate sub-states (first connection only).
    readonly property bool gateConnecting: st === SqlSession.Connecting
    // Ask for a password: never tried yet, or the last failure was an auth error.
    readonly property bool gateAuth: sessionObj && (st === SqlSession.Idle
                        || (st === SqlSession.Failed && sessionObj.errorIsAuth))
    // A non-auth failure (server unreachable, network): show the error + Retry.
    readonly property bool gateServerError: sessionObj && st === SqlSession.Failed && !sessionObj.errorIsAuth

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
    function loadQuery(sql) { page.setEditorText(sql); page.focusEditor() }
    function runSaved(sql) { page.setEditorText(sql); page.run() }
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

    // 1-based editor line of the first server error of the live results that
    // carries one (marked in the editor of the tab that ran), else 0.
    readonly property int errorLine: {
        const ms = sessionObj ? sessionObj.messages : []
        for (let k = 0; k < ms.length; k++) if (ms[k].kind === "error" && ms[k].line > 0) return ms[k].line
        return 0
    }
    // Moves the active editor's caret to the start of a 1-based line.
    function gotoLine(line) {
        if (!editor) return
        const lines = editor.text.split("\n")
        let pos = 0
        for (let k = 0; k < Math.min(line - 1, lines.length); k++) pos += lines[k].length + 1
        editor.cursorPosition = Math.min(pos, editor.length)
        page.focusEditor()
    }

    // ---- deleting rows from a result grid ----
    // At most one delete in flight: {grid, model, indices, rows}.
    property var pendingDelete: null
    function requestDelete(grid, indices, dryRun) {
        if (!sessionObj || !grid.model || pendingDelete) return
        const m = grid.model
        const rows = indices.map(r => m.rowValues(r))
        pendingDelete = { grid: grid, model: m, indices: indices, rows: rows }
        sessionObj.deleteRows(grid.deleteTable, m.columns, rows, dryRun === true)
    }
    Connections {
        target: sessionObj
        enabled: sessionObj
        function onRowsDeleted(count, error, sql, dryRun) {
            const p = page.pendingDelete
            page.pendingDelete = null
            if (p) p.grid.deleteFinished(dryRun ? "" : error)
            if (dryRun) {
                if (error) { page.toast(error, "error"); return }
                page.newQueryTab(sql)
                page.toast(qsTr("DELETE opened in a new query tab — review before running"), "info")
                return
            }
            if (error) { page.toast(error, "error"); return }
            // Drop the rows from the grid — unless a newer query has replaced it.
            if (p) {
                let same = true
                for (let k = 0; k < p.indices.length && same; k++)
                    same = JSON.stringify(p.model.rowValues(p.indices[k])) === JSON.stringify(p.rows[k])
                if (same) p.model.removeRows(p.indices)
            }
            page.toast(qsTr("Deleted %n row(s)", "", count), "info")
        }
    }

    // Ranges [{start,end}] in the editor of the statements the last run executed;
    // used to mark each ran query (gutter square + band) and match its result tab.
    property var ranRanges: []
    // How many statements the editor currently holds (to decide whether marking
    // which one ran is meaningful).
    readonly property int editorStmtCount: editor ? page.splitStatements(editor.text, 0).length : 0

    // ---- Query tabs: several independent editors on one connection ----
    // queryTabs carries each tab's last-saved text; tabModel drives the editor
    // instances (a ListModel, so adding/removing a tab never recreates the
    // others and their undo history survives).
    property var queryTabs: [{ text: "SELECT TOP 100 * FROM INFORMATION_SCHEMA.TABLES" }]
    property int activeQuery: 0
    property int lastRunTab: -1   // which query tab produced the live results
    property int tabSerial: 1
    ListModel { id: tabModel; ListElement { uid: 0 } }
    // Per-tab detached result snapshots (parallel to queryTabs), so switching
    // tabs shows that query's results without re-running. null until a tab runs.
    property var queryResults: [null]
    function saveActiveText() {
        if (!editor || activeQuery < 0 || activeQuery >= queryTabs.length) return
        queryTabs[activeQuery].text = editor.text
    }
    // Snapshot the currently-live results into their owning tab, so they survive
    // when another tab's query reuses the session's live models.
    function captureLiveResults() {
        if (!sessionObj || lastRunTab < 0 || lastRunTab >= queryResults.length) return
        const arr = queryResults.slice()
        arr[lastRunTab] = sessionObj.snapshotResults()
        queryResults = arr
    }
    function selectQueryTab(i) {
        if (i === activeQuery || i < 0 || i >= queryTabs.length) return
        saveActiveText()
        captureLiveResults()
        activeQuery = i
        page.focusEditor()
    }
    // Opens a new query tab, optionally pre-filled (e.g. SQL handed over from
    // elsewhere — never overwriting the current tab).
    function newQueryTab(text) {
        saveActiveText()
        captureLiveResults()
        const arr = queryTabs.slice()
        arr.push({ text: text || "" })
        queryTabs = arr
        const res = queryResults.slice()
        res.push(null)
        queryResults = res
        tabModel.append({ uid: page.tabSerial++ })
        activeQuery = arr.length - 1
        page.focusEditor()
    }
    function closeQueryTab(i) {
        if (queryTabs.length <= 1 || i < 0 || i >= queryTabs.length) return
        if (i === activeQuery) saveActiveText()
        else captureLiveResults()
        const arr = queryTabs.slice()
        arr.splice(i, 1)
        const res = queryResults.slice()
        res.splice(i, 1)
        queryResults = res
        // Keep results/markers pointing at the right tab after the shift.
        if (lastRunTab === i) lastRunTab = -1
        else if (lastRunTab > i) lastRunTab--
        let a = activeQuery
        if (i < a) a--
        else if (i === a) a = Math.min(i, arr.length - 1)
        queryTabs = arr
        activeQuery = a
        tabModel.remove(i)
        page.focusEditor()
    }
    // Distinct colour per result/query: hues spread by the golden angle so even
    // adjacent indices are far apart on the wheel, staying distinguishable well
    // past 20 queries. Saturation/lightness tuned per theme to stay enterprise-muted.
    function resultColor(i) {
        const h = (((i * 137.508) % 360) + 360) % 360 / 360
        return Theme.dark ? Qt.hsla(h, 0.58, 0.66, 1) : Qt.hsla(h, 0.66, 0.46, 1)
    }
    // Splits SQL into statements as [{start, end}] (offsets shifted by `base`),
    // for the result markers, "run current statement" and completion scope.
    // Honours strings, comments, [identifiers] and PostgreSQL $$ quoting; ';'
    // ends a statement only outside parentheses and BEGIN…END / CASE…END; a
    // statement keyword at the start of a line begins a new one unless it
    // continues the current statement (UPDATE…SET, INSERT…SELECT, UNION
    // SELECT, a CTE's main query, IF/ELSE bodies…). SET starts a statement only
    // before a session option or @variable. CREATE PROC/FUNCTION/TRIGGER/VIEW
    // bodies are never split (up to GO; for PostgreSQL, up to the ';' after the
    // dollar-quoted body). Lines holding only GO [n] are batch boundaries.
    function splitStatements(sql, base) {
        const pg = !!(sessionObj && sessionObj.engine === "postgres")
        const startKw = /^(select|insert|update|delete|with|merge|exec|execute|call|create|alter|drop|truncate|declare|set|use|grant|revoke|print|raiserror|throw|if|while|begin|commit|rollback|return)$/
        const setOpt = /^set\s+(@|(ansi_\w+|arith\w+|concat_null_yields_null|context_info|cursor_close_on_commit|datefirst|dateformat|deadlock_priority|fmtonly|forceplan|identity_insert|implicit_transactions|language|lock_timeout|nocount|noexec|numeric_roundabort|parseonly|query_governor_cost_limit|quoted_identifier|remote_proc_transactions|rowcount|showplan_\w+|statistics|textsize|transaction|xact_abort|search_path|role|session|local|time|timezone|client_encoding|client_min_messages|statement_timeout|lock_timeout|work_mem|constraints|names)\b)/i
        const bodyHead = /^(create|alter)\s+(or\s+(alter|replace)\s+)?(proc|procedure|function|trigger|view)\b/i
        const withHead = /^with\s+(recursive\s+)?(\[[^\]]+\]|"[^"]+"|[\w#]+)\s*(\(|as\b)/i
        const goLine = /^go(?:[ \t]+\d+)?[ \t\r]*(?:--[^\n]*)?(?=\n|$)/i
        const contAfter = ["union", "all", "except", "intersect", "for", "else", "then", "do", "as"]
        const out = []
        const n = sql.length
        let i = 0, cur = -1, lastEnd = -1, lineStart = true
        let paren = 0, block = 0, body = false, head = "", pending = false, sawSet = false
        let lastWord = "", lastChar = ""
        const startStmt = (at, word) => {
            cur = at; head = word; paren = 0; block = 0; sawSet = false
            lastWord = ""; lastChar = ""
            body = bodyHead.test(sql.substring(at, at + 200))
            pending = ["insert", "with", "if", "while", "merge"].indexOf(word) !== -1
        }
        const endStmt = (end) => {
            if (cur >= 0) out.push({ start: base + cur, end: base + Math.max(end, cur) })
            cur = -1; body = false; paren = 0; block = 0; head = ""; pending = false
        }
        // Whether a statement keyword at `at` continues the current statement.
        const continues = (w, at) => {
            if (lastChar === "(" || lastChar === "," || lastChar === "=") return true
            if (contAfter.indexOf(lastWord) !== -1) return true
            if (pending) {
                if (head === "insert" && ["select", "with", "exec", "execute"].indexOf(w) !== -1) { pending = false; return true }
                if (head === "with" && ["select", "insert", "update", "delete", "merge"].indexOf(w) !== -1) { pending = false; return true }
                if (head === "if" || head === "while") { pending = false; return true }
            }
            if (head === "merge" && ["insert", "update", "delete", "set"].indexOf(w) !== -1) return true
            if (w === "set") {
                if (head === "update" && !sawSet) { sawSet = true; return true }
                return !setOpt.test(sql.substring(at, at + 80))
            }
            if (w === "with") return !withHead.test(sql.substring(at, at + 200))
            return false
        }
        while (i < n) {
            const c = sql.charAt(i), c2 = sql.charAt(i + 1)
            if (c === '\n') { lineStart = true; i++; continue }
            if (c === ' ' || c === '\t' || c === '\r') { i++; continue }
            if (c === '-' && c2 === '-') { while (i < n && sql.charAt(i) !== '\n') i++; continue }
            if (c === '/' && c2 === '*') {
                const e = sql.indexOf("*/", i + 2)
                i = e < 0 ? n : e + 2
                continue
            }
            if (lineStart && (c === 'g' || c === 'G')) {
                const m = goLine.exec(sql.substring(i, i + 40))
                if (m) {
                    endStmt(lastEnd)
                    i += m[0].length
                    continue
                }
            }
            if (c === "'" || c === '"' || (c === '[' && !pg)) {
                const close = c === '[' ? ']' : c
                if (cur < 0) startStmt(i, "")
                let j = i + 1
                while (j < n) {
                    if (sql.charAt(j) === close) { if (sql.charAt(j + 1) === close) { j += 2; continue } break }
                    j++
                }
                i = Math.min(j + 1, n)
                lastEnd = i; lastChar = close; lastWord = ""; lineStart = false
                continue
            }
            if (pg && c === '$') {
                const m = /^\$([A-Za-z_]\w*)?\$/.exec(sql.substring(i, i + 64))
                if (m) {
                    if (cur < 0) startStmt(i, "")
                    const e = sql.indexOf(m[0], i + m[0].length)
                    i = e < 0 ? n : e + m[0].length
                    lastEnd = i; lastChar = "$"; lastWord = ""; lineStart = false
                    continue
                }
            }
            if (/[A-Za-z_@#]/.test(c)) {
                let j = i + 1
                while (j < n && /[\w@#$]/.test(sql.charAt(j))) j++
                const w = sql.substring(i, j).toLowerCase()
                if (cur < 0) {
                    startStmt(i, w)
                } else if (paren === 0 && block === 0 && !body && startKw.test(w)) {
                    const cont = continues(w, i)
                    if (!cont && lineStart) { endStmt(lastEnd); startStmt(i, w) }
                } else if (head === "update" && w === "set") {
                    sawSet = true
                } else if (head === "insert" && w === "values") {
                    pending = false
                }
                if (w === "case") block++
                else if (w === "end" && block > 0) block--
                else if (w === "begin" && !pg
                         && !/^begin\s+(tran|transaction|distributed|dialog|conversation)\b/i.test(sql.substring(i, i + 40)))
                    block++
                lastWord = w; lastChar = w.charAt(w.length - 1)
                lastEnd = j; lineStart = false
                i = j
                continue
            }
            if (cur < 0) startStmt(i, "")
            if (c === '(') paren++
            else if (c === ')') paren = Math.max(0, paren - 1)
            if (c === ';' && paren === 0 && block === 0 && (!body || pg)) {
                endStmt(i + 1)
                lineStart = true
                i++
                continue
            }
            lastChar = c; lastWord = ""; lastEnd = i + 1; lineStart = false
            i++
        }
        endStmt(lastEnd)
        return out
    }
    // The statement around `pos` in `text`: the one containing it, else the
    // nearest one before it (or an empty range at `pos`).
    function statementAt(text, pos) {
        const st = page.splitStatements(text, 0)
        let best = null
        for (let k = 0; k < st.length; k++) {
            if (st[k].start <= pos && pos <= st[k].end) return st[k]
            if (st[k].start <= pos) best = st[k]
        }
        return best && best.end >= pos - 1 ? best : { start: pos, end: pos }
    }

    // Runs the selection (or the whole editor), or with `currentOnly` just
    // the statement under the caret.
    function run(currentOnly) {
        if (!sessionObj || !editor) return
        page.saveActiveText()
        page.lastRunTab = page.activeQuery
        const all = editor.text
        let sql, base
        if (currentOnly === true) {
            const r = page.statementAt(all, editor.cursorPosition)
            if (r.end <= r.start) return
            sql = all.substring(r.start, r.end)
            base = r.start
        } else {
            const sel = editor.selectedText
            sql = sel.length > 0 ? sel : all
            base = sel.length > 0 ? editor.selectionStart : 0
        }
        page.ranRanges = page.splitStatements(sql, base)
        const lineBase = all.substring(0, base).split("\n").length - 1
        sessionObj.execute(sql, lineBase)
    }
    function fmtSize(kb) {
        if (kb < 0) return ""
        if (kb < 1024) return kb + " KB"
        if (kb < 1048576) return (kb / 1024).toFixed(1) + " MB"
        return (kb / 1048576).toFixed(2) + " GB"
    }

    // ---- SQL autocompletion (logic in components/SqlAssist.js) ----
    function acColor(kind) {
        switch (kind) {
        case "keyword": return Theme.sqlKeyword
        case "function": return Theme.sqlFunction
        case "table": return Theme.sqlTag
        case "view": return Theme.accent
        case "procedure": return Theme.warning
        case "column": return Theme.accent2
        case "cte": return Theme.sqlTag
        case "join": return Theme.success
        case "snippet": return Theme.sqlString
        default: return Theme.textFaint
        }
    }
    onActiveChanged: if (active && everConnected) page.focusEditor()

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
                // Error banner — shown once we've stopped (server error or auth
                // failure), not during the connecting/retrying phase.
                Rectangle {
                    Layout.fillWidth: true
                    visible: sessionObj && sessionObj.errorText !== "" && (page.gateServerError || page.gateAuth)
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

                // Connecting / auto-retrying — spinner + live status, no password
                // prompt. A saved password connects silently; transient failures
                // retry with backoff until they succeed or the user aborts.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: page.gateConnecting
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 11
                        Spinner { size: 18 }
                        Text {
                            Layout.fillWidth: true
                            text: sessionObj ? sessionObj.statusText : qsTr("Connecting…")
                            color: Theme.text; font.pixelSize: Theme.fontMd
                            wrapMode: Text.WordWrap
                        }
                    }
                    // Why the previous try failed, while we keep retrying.
                    Text {
                        Layout.fillWidth: true
                        visible: sessionObj && sessionObj.retryAttempt > 1 && sessionObj.errorText !== ""
                        text: sessionObj ? sessionObj.errorText : ""
                        color: Theme.textFaint; font.pixelSize: Theme.fontXs; wrapMode: Text.WordWrap
                    }
                }

                // Password prompt — first time, or after a wrong password. Typing
                // a new one and connecting updates the saved keychain entry.
                Field {
                    id: pass
                    Layout.fillWidth: true
                    visible: page.gateAuth
                    label: qsTr("Password")
                    password: true
                    onAccepted: gate.submit()
                    onVisibleChanged: if (visible) focusInput()
                    Component.onCompleted: if (visible) focusInput()
                }
                Toggle {
                    id: remember
                    // Only saved connections can persist a password.
                    visible: page.gateAuth && sessionObj && sessionObj.hostId !== ""
                    checked: true
                    label: qsTr("Remember in keychain")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    GhostButton { text: qsTr("Cancel"); onClicked: page.closeRequested() }
                    Item { Layout.fillWidth: true }
                    // Abort an in-progress connect / retry loop.
                    GhostButton {
                        visible: page.gateConnecting
                        text: qsTr("Abort")
                        onClicked: if (sessionObj) sessionObj.abortConnect()
                    }
                    // Retry after a server/network error (reuses the password).
                    PrimaryButton {
                        visible: page.gateServerError
                        text: qsTr("Retry")
                        iconName: "refresh"
                        onClicked: if (sessionObj) sessionObj.reconnect()
                    }
                    // Connect with the entered password.
                    PrimaryButton {
                        visible: page.gateAuth
                        text: qsTr("Connect")
                        iconName: "arrow-right"
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
            Layout.preferredHeight: 40
            color: Theme.surface
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            // The sidebar's divider, continued up to the top of the query tabs
            // (34 tall, on the baseline) so it forms the first tab's left edge.
            Rectangle { x: 235; y: parent.height - 28; width: 1; height: 28; color: Theme.border }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 0

                // Left column: exactly the sidebar's width (236 = 12 margin + 224),
                // so the query tabs start right on the sidebar's divider line.
                Item {
                    Layout.preferredWidth: 224
                    Layout.minimumWidth: 224
                    Layout.maximumWidth: 224
                    Layout.fillHeight: true
                    RowLayout {
                        anchors.fill: parent
                        anchors.topMargin: 12      // centre on the query-tab label line
                        anchors.rightMargin: 10
                        spacing: 10
                // Database context switcher with search (carries its own icon).
                Item {
                    id: dbSwitch
                    // Width follows the database name (icon + text + chevron + padding),
                    // clamped so it neither collapses nor hogs the toolbar.
                    Layout.fillWidth: true
                    implicitHeight: 24
                    enabled: page.live

                    TextMetrics {
                        id: dbLabelMetrics
                        font.pixelSize: Theme.fontMd
                        text: sessionObj ? (sessionObj.currentDatabase || qsTr("(select database)")) : ""
                    }

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
                            Icon { Layout.rightMargin: 10; name: "chevron"; size: 14; color: Theme.textDim; rotation: 90 }
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
                    id: tablesCount
                    text: sessionObj ? qsTr("%1 tables").arg(sessionObj.tables.length) : ""
                    color: Theme.textFaint; font.pixelSize: Theme.fontXs
                }
                    }
                }

                // Query tabs — independent editors on this connection. The bar
                // starts exactly on the sidebar's divider (continued up through
                // the header) and the tabs sit on the header's baseline: inactive
                // tabs are recessed, the active one opens into the editor below.
                Flickable {
                    id: qTabsFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: qTabRow.width
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    Row {
                        id: qTabRow
                        anchors.bottom: parent.bottom
                        height: 28
                        spacing: 0
                        Repeater {
                            model: page.queryTabs.length
                            delegate: AbstractButton {
                                id: qtab
                                required property int index
                                readonly property bool current: page.activeQuery === index
                                height: qTabRow.height
                                hoverEnabled: true
                                focusPolicy: Qt.NoFocus
                                onClicked: page.selectQueryTab(index)
                                implicitWidth: Math.max(100, qlabel.implicitWidth + 10 + 6 + 20 + 4)  // label + gap + close
                                background: Rectangle {
                                    color: qtab.current ? Theme.surface
                                         : (qtab.hovered ? Theme.hover : Theme.surface2)
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                    // Top edge: accent cap on the active tab, hairline otherwise.
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; top: parent.top }
                                        height: qtab.current ? 2 : 1
                                        color: qtab.current ? Theme.accent : Theme.border
                                    }
                                    // Right edge, on the layout grid.
                                    Rectangle {
                                        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                                        width: 1
                                        color: Theme.border
                                    }
                                    // Baseline under inactive tabs; the active tab leaves
                                    // it open so it reads as part of the editor.
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: 1
                                        color: Theme.border
                                        visible: !qtab.current
                                    }
                                }
                                // Label on the left; close pinned to the tab's right edge.
                                contentItem: Item {
                                    Text {
                                        id: qlabel
                                        anchors.left: parent.left; anchors.leftMargin: 10
                                        anchors.right: qclose.left; anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: 1
                                        text: qsTr("Query %1").arg(qtab.index + 1)
                                        elide: Text.ElideRight
                                        color: qtab.current ? Theme.text : Theme.textDim
                                        font.pixelSize: Theme.fontSm
                                        font.weight: qtab.current ? Font.DemiBold : Font.Normal
                                    }
                                    // Close (only when more than one tab).
                                    AbstractButton {
                                        id: qclose
                                        anchors.right: parent.right; anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: 1
                                        visible: page.queryTabs.length > 1
                                        // Always present; quieter on inactive tabs until hovered.
                                        opacity: (qtab.current || qtab.hovered) ? 1 : 0.45
                                        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
                                        width: 20; height: 20
                                        onClicked: page.closeQueryTab(qtab.index)
                                        ToolTip.visible: closeHov.hovered; ToolTip.delay: 600
                                        ToolTip.text: qsTr("Close query")
                                        // Round chip on hover, like browser tabs.
                                        background: Rectangle {
                                            radius: width / 2
                                            color: closeHov.hovered ? Theme.surface3 : "transparent"
                                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                                        }
                                        contentItem: Item {
                                            Icon { anchors.centerIn: parent; name: "tab-close"; size: 14
                                                color: closeHov.hovered ? Theme.text : Theme.textDim }
                                        }
                                        HoverHandler { id: closeHov }
                                    }
                                }
                            }
                        }
                        // New query tab — right after the last tab.
                        AbstractButton {
                            id: qAdd
                            height: qTabRow.height
                            width: 30
                            hoverEnabled: true
                            focusPolicy: Qt.NoFocus
                            onClicked: page.newQueryTab()
                            ToolTip.visible: hovered; ToolTip.delay: 400; ToolTip.text: qsTr("New query")
                            background: Item {
                                Rectangle {
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: 1
                                    width: 22; height: 22; radius: 4
                                    color: qAdd.hovered ? Theme.hover : "transparent"
                                }
                            }
                            contentItem: Item {
                                Icon {
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: 1
                                    name: "plus"; size: 14
                                    color: qAdd.hovered ? Theme.text : Theme.textDim
                                }
                            }
                        }
                    }
                }

                // Paused indicator.
                RowLayout {
                    Layout.leftMargin: 10
                    Layout.topMargin: 12
                    spacing: 6
                    visible: page.paused
                    Rectangle { width: 7; height: 7; radius: 4; color: Theme.textFaint }
                    Text { text: qsTr("Paused"); color: Theme.textDim; font.pixelSize: Theme.fontSm }
                }
                GhostButton {
                    Layout.leftMargin: 10
                    Layout.topMargin: 12
                    visible: page.paused
                    text: qsTr("Resume")
                    onClicked: sessionObj.reconnect()
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

                    id: browserCol
                    readonly property var filteredObjects: {
                        const all = sessionObj ? sessionObj.objects : []
                        const q = tableSearch.text.trim().toLowerCase()
                        return q === "" ? all : all.filter(o => o.name.toLowerCase().indexOf(q) !== -1)
                    }
                    readonly property bool searching: tableSearch.text.trim() !== ""
                    // Groups start collapsed ("folders"); a filter force-expands all
                    // so matches are visible without clicking.
                    property var collapsed: ({ table: true, view: true, procedure: true, function: true })
                    function toggleGroup(t) {
                        const c = {}
                        for (const k in collapsed) c[k] = collapsed[k]
                        c[t] = !(collapsed[t] === true)
                        collapsed = c
                    }
                    // Most-recently-opened objects (session-scoped), newest first.
                    property var recents: []
                    function pushRecent(name, type, args) {
                        const r = recents.filter(o => o.name !== name)
                        r.unshift({ name: name, type: type, args: args || "" })
                        recents = r.slice(0, 6)
                    }
                    // pgAdmin-style per-type glyph and colour, shared by the group
                    // folder and its object rows.
                    function typeIcon(t) {
                        return t === "view" ? "view"
                             : t === "procedure" ? "procedure"
                             : t === "function" ? "function" : "table"
                    }
                    function typeColor(t) {
                        return t === "view" ? Theme.accent
                             : t === "procedure" ? Theme.warning
                             : t === "function" ? Theme.accent2
                             : (sessionObj ? Theme.engineColor(sessionObj.engine) : Theme.sqlTag)
                    }
                    // Flattened rows: a group header followed (when expanded) by its
                    // objects, in the order Tables, Views, Procedures, Functions.
                    readonly property var objectRows: {
                        const order = ["table", "view", "procedure", "function"]
                        const labels = { table: qsTr("Tables"), view: qsTr("Views"),
                                         procedure: qsTr("Procedures"), function: qsTr("Functions") }
                        const rows = []
                        for (const t of order) {
                            const items = filteredObjects.filter(o => o.type === t)
                            if (!items.length) continue
                            const open = searching || !(collapsed[t] === true)
                            rows.push({ header: true, firstHeader: rows.length === 0, type: t,
                                        label: labels[t], count: items.length, open: open })
                            if (open)
                                for (const it of items)
                                    rows.push({ header: false, name: it.name, type: it.type, args: it.args })
                        }
                        return rows
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14; Layout.rightMargin: 10
                        Layout.topMargin: 14; Layout.bottomMargin: 8
                        spacing: 6
                        Text {
                            Layout.fillWidth: true
                            text: qsTr("OBJECTS")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                            font.letterSpacing: 0.8
                        }
                        Text {
                            visible: sessionObj && tableSearch.text !== ""
                            text: parent.parent.filteredObjects.length + " found"
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                        }
                        // Re-read the object list after the schema changes.
                        Rectangle {
                            id: refreshBtn
                            implicitWidth: 24; implicitHeight: 24
                            radius: Theme.radius
                            color: refreshHover.hovered ? Theme.hover : "transparent"
                            opacity: page.live ? 1 : 0.35
                            enabled: opacity === 1
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                            Icon {
                                anchors.centerIn: parent
                                name: "refresh"; size: 14
                                color: refreshHover.hovered ? Theme.text : Theme.textFaint
                                NumberAnimation on rotation {
                                    id: spin; running: false; from: 0; to: 360
                                    duration: 500; easing.type: Easing.OutCubic
                                }
                            }
                            HoverHandler { id: refreshHover; enabled: refreshBtn.enabled }
                            TapHandler {
                                enabled: refreshBtn.enabled
                                onTapped: { if (sessionObj) sessionObj.refreshObjects(); spin.restart() }
                            }
                            ToolTip.visible: refreshHover.hovered
                            ToolTip.text: qsTr("Refresh objects")
                            ToolTip.delay: 500
                        }
                    }
                    // Object filter.
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
                                placeholderText: qsTr("Filter objects")
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
                        model: parent.objectRows
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}
                        property int hoveredIndex: -1
                        HoverHandler { onHoveredChanged: if (!hovered) tablesList.hoveredIndex = -1 }

                        // Opens an object with the action that fits its type: run a
                        // SELECT for tables/views, or stage a call template for a
                        // procedure/function (never auto-run — a proc may write).
                        // Splits a routine signature into individual args on the
                        // top-level commas only (ignoring commas inside type parens
                        // like numeric(10,2)).
                        function splitArgs(sig) {
                            const s = (sig || "").trim()
                            if (s === "") return []
                            const parts = []
                            let depth = 0, start = 0
                            for (let i = 0; i < s.length; ++i) {
                                const ch = s[i]
                                if (ch === "(" || ch === "[") depth++
                                else if (ch === ")" || ch === "]") depth--
                                else if (ch === "," && depth === 0) { parts.push(s.slice(start, i).trim()); start = i + 1 }
                            }
                            parts.push(s.slice(start).trim())
                            return parts.filter(p => p !== "")
                        }

                        function openObject(name, type, args) {
                            browserCol.pushRecent(name, type, args)
                            const isPg = sessionObj && sessionObj.engine === "postgres"
                            if (type === "table" || type === "view") {
                                page.setEditorText(isPg ? ("SELECT * FROM " + name + " LIMIT 100")
                                                        : ("SELECT TOP 100 * FROM " + name))
                                page.run()
                                return
                            }
                            // Procedure/function: stage a call skeleton (never auto-run —
                            // it may write). One NULL placeholder per parameter so the call
                            // has the right shape; each line names the arg to fill in.
                            const parts = splitArgs(args)
                            if (type === "procedure" && !isPg) {
                                // SQL Server: EXEC with named parameters.
                                if (!parts.length) page.setEditorText("EXEC " + name + ";")
                                else {
                                    const body = parts.map((p, i) =>
                                        (i ? "  , " : "    ") + p.split(/\s+/)[0] + " = NULL  -- " + p).join("\n")
                                    page.setEditorText("EXEC " + name + "\n" + body + ";")
                                }
                            } else {
                                const verb = type === "procedure" ? "CALL " : "SELECT * FROM "
                                if (!parts.length) page.setEditorText(verb + name + "();")
                                else {
                                    const body = parts.map((p, i) =>
                                        (i ? "  , " : "    ") + "NULL  -- " + p).join("\n")
                                    page.setEditorText(verb + name + "(\n" + body + "\n);")
                                }
                            }
                            page.focusEditor()
                        }

                        delegate: Item {
                            id: tbd
                            required property int index
                            required property var modelData
                            width: tablesList.width
                            height: modelData.header ? (modelData.firstHeader ? 30 : 34) : 28

                            // Group header row — click to expand/collapse.
                            ItemDelegate {
                                id: groupRow
                                visible: tbd.modelData.header
                                anchors.fill: parent
                                anchors.topMargin: tbd.modelData.firstHeader ? 0 : 6
                                enabled: !browserCol.searching
                                hoverEnabled: true
                                background: Rectangle {
                                    radius: Theme.radius
                                    anchors.leftMargin: 8; anchors.rightMargin: 8
                                    anchors.fill: parent
                                    color: groupRow.hovered ? Theme.hover : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                                contentItem: RowLayout {
                                    anchors.fill: parent
                                    spacing: 7
                                    Icon {
                                        Layout.leftMargin: 12
                                        name: "chevron"; size: 12
                                        color: groupRow.hovered ? Theme.text : Theme.textDim
                                        rotation: tbd.modelData.open ? 90 : 0
                                        Behavior on rotation { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
                                    }
                                    Icon {
                                        name: tbd.modelData.open ? "folder-open" : "folder"; size: 15
                                        color: groupRow.hovered ? Theme.text : Theme.textDim
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: tbd.modelData.label || ""
                                        color: Theme.text; font.pixelSize: Theme.fontSm
                                        font.weight: Font.DemiBold
                                    }
                                    Text {
                                        Layout.rightMargin: 16
                                        text: tbd.modelData.count || ""
                                        color: Theme.textFaint; font.pixelSize: Theme.fontXs
                                    }
                                }
                                onClicked: browserCol.toggleGroup(tbd.modelData.type)
                            }

                            // Object row.
                            ItemDelegate {
                                id: leafRow
                                visible: !tbd.modelData.header
                                anchors.fill: parent
                                readonly property string objType: tbd.modelData.type || "table"
                                readonly property bool hov: tablesList.hoveredIndex === tbd.index
                                HoverHandler {
                                    onHoveredChanged: {
                                        if (hovered) tablesList.hoveredIndex = tbd.index
                                        else if (tablesList.hoveredIndex === tbd.index) tablesList.hoveredIndex = -1
                                    }
                                }
                                background: Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8; anchors.rightMargin: 8
                                    radius: Theme.radius
                                    color: leafRow.hov ? Theme.hover : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                                contentItem: RowLayout {
                                    spacing: 8
                                    // Small type-colour dot — the only colour accent.
                                    Rectangle {
                                        Layout.leftMargin: 30
                                        implicitWidth: 6; implicitHeight: 6; radius: 3
                                        color: browserCol.typeColor(leafRow.objType)
                                    }
                                    Icon {
                                        name: browserCol.typeIcon(leafRow.objType)
                                        size: 14
                                        color: leafRow.hov ? Theme.text : Theme.textDim
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.rightMargin: 12
                                        text: tbd.modelData.name || ""
                                        color: leafRow.hov ? Theme.text : Theme.textDim
                                        font.pixelSize: Theme.fontSm
                                        elide: Text.ElideMiddle
                                    }
                                }
                                onClicked: tablesList.openObject(tbd.modelData.name, leafRow.objType, tbd.modelData.args)
                            }
                        }
                    }

                    // Recently opened objects — quick re-access, pinned to the bottom.
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 8
                        spacing: 0
                        visible: browserCol.recents.length > 0

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.leftMargin: 14; Layout.rightMargin: 14
                            implicitHeight: 1; color: Theme.border; opacity: 0.6
                        }
                        Text {
                            Layout.leftMargin: 14
                            Layout.topMargin: 10; Layout.bottomMargin: 4
                            text: qsTr("RECENT")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                            font.weight: Font.DemiBold; font.letterSpacing: 0.8
                        }
                        Repeater {
                            model: browserCol.recents
                            delegate: ItemDelegate {
                                id: recentRow
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 28
                                readonly property bool hov: hovered
                                background: Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8; anchors.rightMargin: 8
                                    radius: Theme.radius
                                    color: recentRow.hov ? Theme.hover : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                                contentItem: RowLayout {
                                    spacing: 8
                                    Rectangle {
                                        Layout.leftMargin: 16
                                        implicitWidth: 6; implicitHeight: 6; radius: 3
                                        color: browserCol.typeColor(recentRow.modelData.type)
                                    }
                                    Icon {
                                        name: browserCol.typeIcon(recentRow.modelData.type)
                                        size: 14
                                        color: recentRow.hov ? Theme.text : Theme.textDim
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.rightMargin: 12
                                        text: recentRow.modelData.name || ""
                                        color: recentRow.hov ? Theme.text : Theme.textDim
                                        font.pixelSize: Theme.fontSm
                                        elide: Text.ElideMiddle
                                    }
                                }
                                onClicked: tablesList.openObject(recentRow.modelData.name, recentRow.modelData.type, recentRow.modelData.args)
                            }
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
                    // One editor per query tab, only the active one shown, so each
                    // keeps its own undo history, caret, selection and scroll.
                    StackLayout {
                        id: editorStack
                        anchors.fill: parent
                        anchors.topMargin: 4
                        anchors.rightMargin: 4
                        anchors.bottomMargin: 44
                        currentIndex: page.activeQuery
                        Repeater {
                            model: tabModel
                            delegate: SqlEditor {
                                id: tabEditor
                                required property int index
                                readonly property bool current: index === page.activeQuery
                                readonly property bool marked: page.lastRunTab === index && page.editorStmtCount > 1
                                host: page
                                initialText: index >= 0 && index < page.queryTabs.length ? page.queryTabs[index].text : ""
                                schema: sessionObj ? sessionObj.schema : ({})
                                engine: sessionObj ? sessionObj.engine : "mssql"
                                markRanges: marked ? page.ranRanges : []
                                activeMark: marked && !resultsArea.messagesShown ? resultsArea.activeResult : -1
                                errorLine: page.lastRunTab === index ? page.errorLine : 0
                                function claim() { page.editor = tabEditor.area; page.editorView = tabEditor }
                                onCurrentChanged: if (current) claim()
                                Component.onCompleted: if (current) claim()
                            }
                        }
                    }
                    RowLayout {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        anchors.margins: 8
                        spacing: 8
                        Text {
                            Layout.leftMargin: 4
                            text: page.paused ? qsTr("Paused — ⌘↵ resumes and runs")
                                              : qsTr("⌘↵ runs the query (or the selection) · ⇧⌘↵ the current statement")
                            color: Theme.textFaint; font.pixelSize: Theme.fontXs
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.minimumWidth: 60
                        }
                        // Scripts split by GO: stop at the first failing batch, or
                        // keep going and report every error.
                        Toggle {
                            visible: sessionObj && sessionObj.engine !== "postgres"
                            label: qsTr("Stop on error")
                            checked: sessionObj ? sessionObj.stopOnError : true
                            onToggled: if (sessionObj) sessionObj.stopOnError = checked
                            ToolTip.visible: hovered; ToolTip.delay: 500
                            ToolTip.text: qsTr("For scripts split by GO: stop at the first batch that fails")
                        }
                        GhostButton {
                            text: qsTr("Format")
                            implicitHeight: 30
                            leftPadding: 12; rightPadding: 12
                            enabled: page.editor && page.editor.text.trim() !== ""
                            opacity: enabled ? 1 : 0.5
                            onClicked: page.editorView.formatSql()
                            ToolTip.visible: hovered; ToolTip.delay: 500
                            ToolTip.text: qsTr("Format SQL (⇧⌥F) — the selection, or everything")
                        }

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
                                    text: qsTr("Saved queries")
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
                            visible: page.st !== SqlSession.Executing
                            text: page.st === SqlSession.Connecting ? qsTr("Resuming…")
                                : page.paused ? qsTr("Resume & run") : qsTr("Run")
                            iconName: "arrow-right"
                            implicitHeight: 30
                            leftPadding: 14; rightPadding: 14
                            enabled: !page.busy
                            onClicked: page.run()
                        }
                        // While a query runs: cancel it (Esc / ⌘.). The connection stays open.
                        PrimaryButton {
                            visible: page.st === SqlSession.Executing
                            destructive: true
                            text: qsTr("Stop")
                            iconName: "x"
                            implicitHeight: 30
                            leftPadding: 14; rightPadding: 14
                            onClicked: if (sessionObj) sessionObj.cancel()
                            ToolTip.visible: hovered; ToolTip.delay: 500
                            ToolTip.text: qsTr("Cancel the running query (Esc)")
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

                    // The active tab shows live session results when its query is
                    // the one that last ran; otherwise it shows its own snapshot.
                    readonly property bool liveShown: page.lastRunTab === page.activeQuery
                    readonly property var snap: (page.queryResults && page.activeQuery >= 0
                                                 && page.activeQuery < page.queryResults.length)
                                                ? page.queryResults[page.activeQuery] : null
                    readonly property var models: liveShown ? (sessionObj ? sessionObj.resultModels : [])
                                                            : (snap ? snap.models : [])
                    readonly property var res: liveShown ? (sessionObj ? sessionObj.result : null)
                                                         : (snap && snap.models.length ? snap.models[0] : null)
                    readonly property int count: models.length
                    readonly property bool hasGrid: count > 0
                    readonly property string viewError: liveShown ? (sessionObj ? sessionObj.errorText : "")
                                                                  : (snap ? (snap.error || "") : "")
                    readonly property string viewMessage: liveShown ? (sessionObj ? sessionObj.message : "")
                                                                    : (snap ? (snap.message || "") : "")
                    // Server messages / row counts / errors of the shown run.
                    readonly property var viewMessages: liveShown ? (sessionObj ? sessionObj.messages : [])
                                                                  : (snap ? (snap.messages || []) : [])
                    readonly property bool hasMessages: viewMessages.length > 0
                    // Server-side record search only for a lone single-table read.
                    readonly property string serverTable: sessionObj ? sessionObj.statsTable : ""
                    // The table a lone single-table result came from, for deleting
                    // rows: the live session's detection, or the snapshot's.
                    readonly property string sourceTable: count !== 1 ? ""
                        : liveShown ? serverTable : (snap ? (snap.statsTable || "") : "")
                    property var activeGrid: null       // grid the keyboard copy acts on

                    // Which result set (tab) is shown for a multi-statement batch,
                    // or whether the Messages tab is.
                    property int activeResult: 0
                    property bool messagesShown: false

                    // Runs SQL from the grid (server-side search): put it in the
                    // editor as one undoable step, then run it.
                    function exec(sql) { page.setEditorText(sql); page.run() }
                    // SQL handed over without running it opens in a new query tab,
                    // never overwriting the current one.
                    function stage(sql) { page.newQueryTab(sql) }

                    // A fresh batch resets the selected tab; one that failed after
                    // producing results opens on its messages, like SSMS.
                    Connections {
                        target: sessionObj
                        enabled: sessionObj
                        function onResultsChanged() { resultsArea.activeResult = 0 }
                        function onMessageChanged() {
                            resultsArea.messagesShown = sessionObj.errorText !== "" || sessionObj.cancelled
                        }
                    }
                    // Switching query tabs resets to that tab's first result set.
                    Connections {
                        target: page
                        function onActiveQueryChanged() { resultsArea.activeResult = 0; resultsArea.messagesShown = false }
                    }
                    // Micro fade when switching between result tabs.
                    NumberAnimation {
                        id: gridFade
                        target: theGrid; property: "opacity"
                        from: 0.45; to: 1; duration: Theme.normal; easing.type: Theme.easing
                    }
                    onActiveResultChanged: if (resultsArea.count > 1) gridFade.restart()

                    ColumnLayout {
                        anchors.fill: parent
                        visible: resultsArea.hasGrid || resultsArea.hasMessages
                        spacing: 0

                        // Result tabs — one per set, each with its colour square,
                        // plus Messages; shown when there is more than one thing to see.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            visible: resultsArea.count > 1 || (resultsArea.hasGrid && resultsArea.hasMessages)
                            color: Theme.surface
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                            Flickable {
                                id: tabsFlick
                                anchors.fill: parent
                                anchors.leftMargin: 6; anchors.rightMargin: 6
                                contentWidth: tabRow.implicitWidth
                                contentHeight: height
                                clip: true
                                flickableDirection: Flickable.HorizontalFlick
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded; height: 3 }
                                // Keep the selected tab in view when it changes.
                                function ensureVisible(x, w) {
                                    if (x < contentX) contentX = Math.max(0, x - 8)
                                    else if (x + w > contentX + width) contentX = Math.min(contentWidth - width, x + w - width + 8)
                                }
                                Row {
                                    id: tabRow
                                    height: tabsFlick.height
                                    Repeater {
                                        model: (resultsArea.count > 1 || resultsArea.hasMessages) ? resultsArea.count : 0
                                        delegate: Row {
                                            id: tabCell
                                            required property int index
                                            height: tabRow.height
                                            AbstractButton {
                                                id: tab
                                                height: tabRow.height
                                                hoverEnabled: true
                                                focusPolicy: Qt.NoFocus
                                                readonly property bool current: !resultsArea.messagesShown && resultsArea.activeResult === tabCell.index
                                                readonly property var m: resultsArea.models[tabCell.index]
                                                onClicked: {
                                                    resultsArea.messagesShown = false
                                                    resultsArea.activeResult = tabCell.index
                                                    resultsArea.activeGrid = theGrid
                                                    tabsFlick.ensureVisible(tabCell.x, tabCell.width)
                                                }
                                                contentItem: RowLayout {
                                                    spacing: 7
                                                    Rectangle {
                                                        Layout.leftMargin: 11; Layout.alignment: Qt.AlignVCenter
                                                        width: 10; height: 10; radius: 3
                                                        color: page.resultColor(tabCell.index)
                                                        opacity: tab.current ? 1 : 0.65
                                                        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
                                                    }
                                                    Text {
                                                        text: qsTr("Result %1").arg(tabCell.index + 1)
                                                        color: tab.current ? Theme.text : Theme.textDim
                                                        font.pixelSize: Theme.fontSm
                                                        font.weight: tab.current ? Font.DemiBold : Font.Normal
                                                    }
                                                    Text {
                                                        Layout.rightMargin: 13
                                                        visible: tab.m && tab.m.rows !== undefined
                                                        text: tab.m ? tab.m.rows : ""
                                                        color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily
                                                    }
                                                }
                                                background: Rectangle {
                                                    color: tab.current ? Theme.surface2 : (tab.hovered ? Theme.hover : "transparent")
                                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                                    Rectangle {
                                                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                                        height: 2
                                                        color: page.resultColor(tabCell.index)
                                                        opacity: tab.current ? 1 : 0
                                                        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                                                    }
                                                }
                                            }
                                            // Divider between tabs.
                                            Rectangle {
                                                width: 1; height: Math.round(tabRow.height * 0.46)
                                                anchors.verticalCenter: parent.verticalCenter
                                                color: Theme.border
                                                visible: tabCell.index < resultsArea.count - 1 || resultsArea.hasMessages
                                            }
                                        }
                                    }
                                    // Messages: PRINT / NOTICE output, row counts, errors.
                                    AbstractButton {
                                        id: msgTab
                                        visible: resultsArea.hasMessages
                                        height: tabRow.height
                                        hoverEnabled: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property bool current: resultsArea.messagesShown
                                        readonly property bool hasError: resultsArea.viewMessages.some(m => m.kind === "error")
                                        onClicked: resultsArea.messagesShown = true
                                        contentItem: RowLayout {
                                            spacing: 7
                                            Icon {
                                                Layout.leftMargin: 11
                                                name: msgTab.hasError ? "alert" : "enter"; size: 12
                                                color: msgTab.hasError ? Theme.danger : Theme.textDim
                                            }
                                            Text {
                                                Layout.rightMargin: 13
                                                text: qsTr("Messages")
                                                color: msgTab.current ? Theme.text : Theme.textDim
                                                font.pixelSize: Theme.fontSm
                                                font.weight: msgTab.current ? Font.DemiBold : Font.Normal
                                            }
                                        }
                                        background: Rectangle {
                                            color: msgTab.current ? Theme.surface2 : (msgTab.hovered ? Theme.hover : "transparent")
                                            Rectangle {
                                                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                                height: 2
                                                color: msgTab.hasError ? Theme.danger : Theme.textDim
                                                opacity: msgTab.current ? 1 : 0
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // The visible grid: the selected tab's set, or the lone result.
                        ResultGrid {
                            id: theGrid
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: resultsArea.hasGrid && !resultsArea.messagesShown
                            model: resultsArea.count > 1
                                   ? resultsArea.models[Math.min(resultsArea.activeResult, resultsArea.count - 1)]
                                   : resultsArea.res
                            ordinal: resultsArea.count > 1 ? resultsArea.activeResult : 0
                            stacked: false
                            // Server-side search only applies to a lone single-table read.
                            serverTable: (resultsArea.liveShown && resultsArea.count === 1) ? resultsArea.serverTable : ""
                            onToast: (m, k) => page.toast(m, k)
                            onServerSearch: (sql) => resultsArea.exec(sql)
                            onStageSql: (sql) => resultsArea.stage(sql)
                            onActivated: resultsArea.activeGrid = theGrid
                            Component.onCompleted: resultsArea.activeGrid = theGrid
                            deleteTable: serverTable !== "" ? serverTable : resultsArea.sourceTable
                            deleteBlockedReason: resultsArea.count > 1
                                ? qsTr("Deleting rows works on a single result set — run one SELECT on its own.")
                                : qsTr("Can't tell which table these rows came from — deleting works on a single-table SELECT result.")
                            onDeleteRequested: (indices, dryRun) => page.requestDelete(theGrid, indices, dryRun)
                        }

                        // Messages pane: server messages, row counts and errors, in
                        // order. Text is selectable (Cmd+C); hover a row to copy it or,
                        // for an error with a line number, jump the editor there.
                        ListView {
                            id: msgList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: resultsArea.messagesShown || !resultsArea.hasGrid
                            clip: true
                            topMargin: 8; bottomMargin: 8
                            model: visible ? resultsArea.viewMessages : []
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {}
                            function lineText(m) {
                                return (m.line > 0 ? qsTr("Line %1: ").arg(m.line) : "") + m.text
                            }
                            function copyAll() {
                                Clipboard.copy(resultsArea.viewMessages.map(m => msgList.lineText(m)).join("\n"))
                                page.toast(qsTr("Messages copied"), "info")
                            }
                            header: Item {
                                width: msgList.width
                                height: msgList.count > 1 ? 32 : 0
                                visible: msgList.count > 1
                                GhostButton {
                                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                    implicitHeight: 26
                                    text: qsTr("Copy all")
                                    onClicked: msgList.copyAll()
                                }
                            }
                            delegate: Item {
                                id: msgRow
                                required property var modelData
                                width: msgList.width
                                height: msgText.implicitHeight + 6
                                readonly property bool isError: modelData.kind === "error"
                                readonly property bool jumpable: isError && modelData.line > 0
                                HoverHandler { id: msgHover }
                                TextEdit {
                                    id: msgText
                                    anchors { left: parent.left; right: rowActions.left; leftMargin: 14; rightMargin: 8
                                              verticalCenter: parent.verticalCenter }
                                    text: msgList.lineText(msgRow.modelData)
                                    readOnly: true
                                    selectByMouse: true
                                    selectionColor: Theme.accent
                                    selectedTextColor: "white"
                                    color: msgRow.isError ? Theme.danger
                                         : msgRow.modelData.kind === "rows" ? Theme.textDim : Theme.text
                                    font.family: Theme.monoFamily; font.pixelSize: Theme.fontSm
                                    wrapMode: Text.Wrap
                                }
                                Row {
                                    id: rowActions
                                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                    spacing: 2
                                    opacity: msgHover.hovered ? 1 : 0
                                    IconButton {
                                        visible: msgRow.jumpable
                                        iconName: "arrow-right"; iconSize: 14
                                        tip: qsTr("Go to line %1").arg(msgRow.modelData.line)
                                        onClicked: page.gotoLine(msgRow.modelData.line)
                                    }
                                    IconButton {
                                        iconName: "copy"; iconSize: 14
                                        tip: qsTr("Copy")
                                        onClicked: {
                                            Clipboard.copy(msgList.lineText(msgRow.modelData))
                                            page.toast(qsTr("Copied"), "info")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Empty / message / error state.
                    Column {
                        anchors.centerIn: parent
                        spacing: 10
                        visible: !resultsArea.hasGrid && !resultsArea.hasMessages
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: resultsArea.viewError ? "alert" : "database"
                            size: 26
                            color: resultsArea.viewError ? Theme.danger : Theme.textFaint
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 420; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            text: resultsArea.viewError ? resultsArea.viewError
                                : resultsArea.viewMessage ? resultsArea.viewMessage
                                : qsTr("Run a query to see results.")
                            color: resultsArea.viewError ? Theme.danger : Theme.textDim
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
                            visible: resultsArea.liveShown && sessionObj && sessionObj.statsTable !== ""
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
                            visible: resultsArea.liveShown && sessionObj && sessionObj.statsTable !== "" && sessionObj.tableRowCount >= 0
                            width: 1; height: 12; color: Theme.border
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: resultsArea.res && resultsArea.res.columns.length > 0
                            text: resultsArea.res
                                  ? resultsArea.res.rows + qsTr(" shown")
                                    + (resultsArea.liveShown && sessionObj ? qsTr(" · ") + sessionObj.elapsedMs + " ms" : "")
                                  : ""
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
    // F5 as in SSMS; Shift adds "just the statement under the caret".
    Shortcut { sequence: "F5"; enabled: page.active && !page.busy; onActivated: page.run() }
    Shortcut { sequences: ["Ctrl+Shift+Return", "Ctrl+Shift+Enter", "Meta+Shift+Return", "Meta+Shift+Enter"]
               enabled: page.active; onActivated: page.run(true) }
    // Cancel a running query: Esc or Cmd+. (only while executing, so Esc keeps
    // its usual meaning otherwise).
    Shortcut { sequences: ["Esc", "Ctrl+.", "Meta+."]; enabled: page.active && page.st === SqlSession.Executing
               onActivated: if (sessionObj) sessionObj.cancel() }
    // Editor: find / replace, format.
    Shortcut { sequences: [StandardKey.Find]; enabled: page.active && page.editorView
               onActivated: page.editorView.openFind(false) }
    Shortcut { sequence: "Ctrl+Alt+F"; enabled: page.active && page.editorView
               onActivated: page.editorView.openFind(true) }
    Shortcut { sequence: "Shift+Alt+F"; enabled: page.active && page.editorView
               onActivated: page.editorView.formatSql() }
    // Delete the ticked rows (or the current row) of the focused grid — not
    // while typing in a text field.
    Shortcut {
        sequences: ["Delete", "Backspace"]
        enabled: {
            if (!page.active || !resultsArea.activeGrid || !resultsArea.activeGrid.visible) return false
            const g = resultsArea.activeGrid
            if (g.selRow < 0 && g.checkCount === 0) return false
            const f = page.Window.activeFocusItem
            return !(f && ("cursorPosition" in f))
        }
        onActivated: resultsArea.activeGrid.askDelete()
    }
    // Copy the selected cell; Shift adds the whole row. Only when a cell is
    // selected, so the editor keeps normal copy while it has focus.
    Shortcut { sequences: [StandardKey.Copy]; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copySel() }
    Shortcut { sequence: "Ctrl+Shift+C"; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copyRow() }
    Shortcut { sequence: "Meta+Shift+C"; enabled: page.active && resultsArea.activeGrid && resultsArea.activeGrid.selRow >= 0; onActivated: resultsArea.activeGrid.copyRow() }
}
