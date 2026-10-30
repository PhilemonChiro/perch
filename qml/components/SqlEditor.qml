import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay
import "SqlAssist.js" as Assist

// One query tab's SQL editor. Each tab owns an instance, so its undo/redo
// history, caret, selection and scroll survive tab switches. Every
// programmatic change goes through SqlEditorOps (a QTextCursor edit block) so
// it is a single undo step rather than a reset of the undo stack.
//
// Adds a line-number gutter (current line, server error line), bracket
// matching, find/replace, line editing commands, auto-indent and auto-closing
// pairs, schema-aware completion with snippets, and parameter hints.
Item {
    id: root

    property var host                    // the SqlPage: statement bounds, colours
    property string initialText: ""
    property var schema: ({})            // SqlSession.schema
    property string engine: "mssql"
    property var markRanges: []          // statements of the last run, when shown
    property int activeMark: -1          // which of them the open result maps to
    property int errorLine: 0            // 1-based editor line of a server error
    readonly property alias area: ed
    readonly property bool findOpen: findBar.visible

    // ---- programmatic edits (each one undo step) ----
    function setText(t) {
        ed.acSuppress = true
        SqlEditorOps.replaceAll(ed.textDocument, t)
        ed.cursorPosition = ed.length
    }
    function replaceSelection(t) {
        const s = ed.selectionStart, e = ed.selectionEnd
        const at = SqlEditorOps.replaceRange(ed.textDocument, s, e, t)
        ed.cursorPosition = at
    }
    function applySel(r) { ed.select(r.start, r.end) }
    function toggleComment() { applySel(SqlEditorOps.toggleComment(ed.textDocument, ed.selectionStart, ed.selectionEnd)) }
    function duplicateLines() { applySel(SqlEditorOps.duplicateLines(ed.textDocument, ed.selectionStart, ed.selectionEnd)) }
    function moveLines(dir) { applySel(SqlEditorOps.moveLines(ed.textDocument, ed.selectionStart, ed.selectionEnd, dir)) }
    function indent(out) { applySel(SqlEditorOps.indentLines(ed.textDocument, ed.selectionStart, ed.selectionEnd, out)) }
    function formatSql() {
        const pg = root.engine === "postgres"
        if (ed.selectedText.length > 0) {
            const s = ed.selectionStart
            const f = SqlEditorOps.formatSql(ed.selectedText, pg)
            const at = SqlEditorOps.replaceRange(ed.textDocument, s, ed.selectionEnd, f)
            ed.select(s, at)
        } else if (ed.text.trim() !== "") {
            ed.acSuppress = true
            const f = SqlEditorOps.formatSql(ed.text, pg)
            SqlEditorOps.replaceAll(ed.textDocument, f)
            ed.cursorPosition = Math.min(ed.cursorPosition, ed.length)
        }
    }
    function openFind(withReplace) {
        findBar.replaceMode = withReplace
        findBar.visible = true
        if (ed.selectedText.length > 0 && ed.selectedText.indexOf("\n") < 0)
            findField.text = ed.selectedText
        findField.forceActiveFocus()
        findField.selectAll()
        findBar.refresh()
    }
    function closeFind() {
        findBar.visible = false
        ed.forceActiveFocus()
    }

    Rectangle { anchors.fill: parent; color: Theme.surface }

    // ---- gutter: line numbers, current line, error line ----
    Item {
        id: gutter
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(2, String(ed.lineCount).length) * 8 + 20
        clip: true
        readonly property real lh: Math.max(1, ed.cursorRectangle.height)
        readonly property real y0: ed.topPadding   // y of the first line inside the editor
        readonly property real scrollY: sv.contentItem ? sv.contentItem.contentY : 0
        readonly property int first: Math.max(0, Math.floor((scrollY - y0) / lh) - 1)
        readonly property int curLine: Math.round((ed.cursorRectangle.y - y0) / lh)
        Repeater {
            model: Math.max(0, Math.min(ed.lineCount - gutter.first, Math.ceil(gutter.height / gutter.lh) + 2))
            delegate: Item {
                id: gl
                required property int index
                readonly property int line: gutter.first + index
                readonly property bool isError: root.errorLine > 0 && line === root.errorLine - 1
                // Mapped from the editor so it tracks scrolling and padding exactly.
                y: { gutter.scrollY; gutter.height; return ed.mapToItem(gutter, 0, gutter.y0 + line * gutter.lh).y }
                width: gutter.width; height: gutter.lh
                Rectangle {
                    visible: gl.isError
                    anchors.left: parent.left; anchors.leftMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5; height: 5; radius: 2.5; color: Theme.danger
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: gl.line + 1
                    color: gl.isError ? Theme.danger : gl.line === gutter.curLine ? Theme.textDim : Theme.textFaint
                    font.family: Theme.monoFamily; font.pixelSize: Theme.fontXs
                    font.weight: gl.line === gutter.curLine ? Font.DemiBold : Font.Normal
                }
            }
        }
    }

    ScrollView {
        id: sv
        anchors { left: gutter.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        clip: true
        TextArea {
            id: ed
            // Set once, not bound: a later rebinding would replace the text and
            // wipe this tab's undo history.
            Component.onCompleted: text = root.initialText
            color: Theme.text
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontMd
            selectByMouse: true
            persistentSelection: true
            wrapMode: TextArea.NoWrap
            placeholderText: qsTr("Write SQL — ⌘↵ to run")
            leftPadding: 20   // room for the per-statement result squares
            topPadding: 6

            // Bracket pair around the caret, as [open, close] or [].
            property var bracketPair: []
            function updateBracket() {
                const t = text, p = cursorPosition
                let at = -1
                if (p > 0 && "()[]".indexOf(t.charAt(p - 1)) >= 0) at = p - 1
                else if ("()[]".indexOf(t.charAt(p)) >= 0) at = p
                const m = at >= 0 ? SqlEditorOps.matchBracket(t, at) : -1
                bracketPair = m >= 0 ? [at, m] : []
            }

            background: Item {
                // Current line.
                Rectangle {
                    visible: ed.activeFocus && ed.selectedText.length === 0
                    y: ed.cursorRectangle.y; height: ed.cursorRectangle.height
                    width: ed.width
                    color: Theme.accentFaint
                    opacity: 0.6
                }
                // Server error line.
                Rectangle {
                    visible: root.errorLine > 0 && root.errorLine <= ed.lineCount
                    y: gutter.y0 + (root.errorLine - 1) * gutter.lh
                    height: gutter.lh; width: ed.width
                    color: Theme.dangerSoft
                    Rectangle { width: 2; height: parent.height; color: Theme.danger }
                }
                // Faint band behind the query whose result is currently open —
                // follows the selected result tab, gliding between lines.
                Rectangle {
                    id: activeBand
                    readonly property int ri: Math.min(root.activeMark, root.markRanges.length - 1)
                    readonly property bool shown: ri >= 0
                    readonly property var rng: shown ? root.markRanges[ri] : null
                    readonly property color c: root.host ? root.host.resultColor(ri >= 0 ? ri : 0) : Theme.accent
                    // Effective end: trim trailing whitespace so the band stops at
                    // the last real character of the statement, not the next line.
                    readonly property int endEff: {
                        if (!rng) return 0
                        let e = rng.end; const t = ed.text
                        while (e > rng.start && /\s/.test(t.charAt(e - 1))) e--
                        return e
                    }
                    readonly property rect r0: rng ? ed.positionToRectangle(rng.start) : Qt.rect(0, 0, 0, 0)
                    readonly property rect rEnd: rng ? ed.positionToRectangle(endEff) : Qt.rect(0, 0, 0, 0)
                    readonly property bool singleLine: Math.abs(rEnd.y - r0.y) < 1
                    visible: shown
                    x: 0
                    // Hug the query text on a single line; fall back to full width
                    // for a multi-line statement (where a tight box would look odd).
                    width: singleLine ? Math.min(ed.width, rEnd.x + 8) : ed.width
                    y: r0.y
                    height: Math.max(r0.height, (rEnd.y + rEnd.height) - r0.y)
                    radius: 3
                    color: Qt.rgba(c.r, c.g, c.b, 0.10)
                    Rectangle { anchors.left: parent.left; width: 2; height: parent.height; color: activeBand.c }
                    Behavior on y { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                    Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                    Behavior on height { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                }
                // Find matches.
                Repeater {
                    model: findBar.visible ? findBar.matches.slice(0, 400) : []
                    delegate: Rectangle {
                        required property int index
                        required property var modelData
                        readonly property rect a: ed.positionToRectangle(modelData.start)
                        readonly property rect b: ed.positionToRectangle(modelData.end)
                        x: a.x; y: a.y; height: a.height
                        width: Math.abs(b.y - a.y) < 1 ? Math.max(2, b.x - a.x) : ed.width - a.x
                        radius: 2
                        color: index === findBar.current ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.45)
                                                         : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.2)
                    }
                }
                // Matching brackets.
                Repeater {
                    model: ed.bracketPair
                    delegate: Rectangle {
                        required property var modelData
                        readonly property rect a: ed.positionToRectangle(modelData)
                        readonly property rect b: ed.positionToRectangle(modelData + 1)
                        x: a.x; y: a.y; height: a.height
                        width: Math.max(4, b.x - a.x)
                        radius: 2
                        color: "transparent"
                        border.color: Theme.accent
                        border.width: 1
                    }
                }
            }

            // Colour square beside each statement of the last run, so which
            // query ran (and which result tab it maps to) is always clear.
            Repeater {
                model: root.markRanges
                delegate: Rectangle {
                    id: sq
                    required property int index
                    required property var modelData
                    readonly property rect r: ed.positionToRectangle(modelData.start)
                    width: 9; height: 9; radius: 2.5
                    x: 5
                    y: r.y + (r.height - height) / 2
                    color: root.host ? root.host.resultColor(index) : Theme.accent
                    opacity: 0.9
                    NumberAnimation on scale { from: 0; to: 1; duration: Theme.normal; easing.type: Theme.easingEmph }
                }
            }

            // ---- completion / signature / snippet state ----
            property var acItems: []
            property int acIndex: 0
            property int acStart: -1      // where the replaced word begins
            property bool acSuppress: false
            property var snip: null       // {stops: [abs offsets], k, len}
            property string sigHtml: ""

            function stmtAt(pos) {
                return root.host ? root.host.statementAt(text, pos) : { start: 0, end: length }
            }
            function acHide() { if (acPopup.visible) acPopup.close() }
            function acUpdate(manual) {
                if (acSuppress && !manual) { acSuppress = false; return }
                acSuppress = false
                if (!activeFocus || selectedText.length > 0) { acHide(); return }
                const pos = cursorPosition
                if (SqlEditorOps.lexStateAt(text, pos) !== 0) { acHide(); return }
                const res = Assist.complete(text, pos, stmtAt(pos), root.schema, root.engine, manual)
                if (!res) { acHide(); return }
                acStart = res.start
                acItems = res.items
                acIndex = 0
                const r = cursorRectangle
                acPopup.x = Math.max(0, Math.min(r.x, ed.width - acPopup.width - 4))
                acPopup.y = r.y + r.height + 2
                if (!acPopup.visible) acPopup.open()
            }
            function acAccept() {
                if (!acPopup.visible || acItems.length === 0) return
                const item = acItems[acIndex]
                const pos = cursorPosition
                acSuppress = true
                acHide()
                if (item.snippet) {
                    const ex = Assist.expandSnippet(item.snippet, root.engine)
                    const start = acStart
                    SqlEditorOps.replaceRange(textDocument, start, pos, ex.text)
                    const stops = ex.stops.map(o => start + o)
                    cursorPosition = stops.length ? stops[0] : start + ex.text.length
                    snip = stops.length > 1 ? { stops: stops, k: 0, len: length } : null
                    return
                }
                cursorPosition = SqlEditorOps.replaceRange(textDocument, acStart, pos, item.insert)
            }
            // Next snippet tab stop; stops after the one just edited shift by
            // however much the text grew since the last jump.
            function snipNext() {
                if (!snip) return false
                const delta = length - snip.len
                const k = snip.k + 1
                if (k >= snip.stops.length) { snip = null; return false }
                const stops = snip.stops.slice()
                for (let j = k; j < stops.length; j++) stops[j] += delta
                cursorPosition = Math.min(stops[k], length)
                snip = k + 1 < stops.length ? { stops: stops, k: k, len: length } : null
                return true
            }
            function sigUpdate() {
                if (!activeFocus || SqlEditorOps.lexStateAt(text, cursorPosition) !== 0) { sigHtml = ""; return }
                const s = Assist.signature(text, cursorPosition, stmtAt(cursorPosition), root.schema, root.engine)
                sigHtml = s ? s.html : ""
            }
            // Replaces the selection (or inserts at the caret) as one undo step.
            function put(t, caretOffset) {
                const s = selectionStart
                SqlEditorOps.replaceRange(textDocument, s, selectionEnd, t)
                cursorPosition = s + (caretOffset === undefined ? t.length : caretOffset)
            }

            // Deferred refreshes after an edit or caret move, coalesced into one
            // pass per event-loop turn. A Timer (not Qt.callLater) so nothing
            // fires after this tab's editor is destroyed.
            property bool pendingAc: false
            Timer {
                id: deferred
                interval: 0
                onTriggered: {
                    if (ed.pendingAc) { ed.pendingAc = false; ed.acUpdate(false) }
                    ed.updateBracket()
                    ed.sigUpdate()
                    if (findBar.visible) findBar.refresh()
                }
            }
            onTextChanged: {
                pendingAc = true
                deferred.restart()
            }
            onCursorPositionChanged: {
                deferred.restart()
                if (snip && (cursorPosition < snip.stops[0] - 1 || cursorPosition > snip.stops[snip.stops.length - 1] + (length - snip.len) + 1))
                    snip = null
            }
            onActiveFocusChanged: if (!activeFocus) { acHide(); sigHtml = "" }

            Keys.onPressed: (event) => {
                const cmd = (event.modifiers & Qt.ControlModifier) !== 0   // Cmd on macOS
                const ctl = (event.modifiers & Qt.MetaModifier) !== 0      // Control on macOS
                const alt = (event.modifiers & Qt.AltModifier) !== 0
                const k = event.key
                if (acPopup.visible) {
                    const plain = !cmd && !ctl && !alt
                    if (k === Qt.Key_Down) { acIndex = Math.min(acIndex + 1, acItems.length - 1); event.accepted = true; return }
                    if (k === Qt.Key_Up) { acIndex = Math.max(acIndex - 1, 0); event.accepted = true; return }
                    if (plain && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Tab)) { acAccept(); event.accepted = true; return }
                    if (k === Qt.Key_Escape) { acHide(); event.accepted = true; return }
                    if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Home || k === Qt.Key_End
                        || k === Qt.Key_PageUp || k === Qt.Key_PageDown)
                        acHide()   // let the caret move; don't keep a stale list
                }
                if (k === Qt.Key_Space && (ctl || cmd)) { acUpdate(true); event.accepted = true; return }
                if (k === Qt.Key_Escape) {
                    if (sigHtml !== "") { sigHtml = ""; event.accepted = true }
                    if (snip) { snip = null; event.accepted = true }
                    if (findBar.visible) { root.closeFind(); event.accepted = true }
                    return
                }
                if (k === Qt.Key_Tab && !cmd && !ctl && !alt) {
                    if (!snipNext()) {
                        if (selectedText.indexOf("\n") >= 0) root.indent(false)
                        else put("    ")
                    }
                    event.accepted = true
                    return
                }
                if (k === Qt.Key_Backtab) { root.indent(true); event.accepted = true; return }
                if (cmd && !alt && k === Qt.Key_Slash) { root.toggleComment(); event.accepted = true; return }
                if (cmd && !alt && !ctl && k === Qt.Key_D) { root.duplicateLines(); event.accepted = true; return }
                if (alt && !cmd && (k === Qt.Key_Up || k === Qt.Key_Down)) {
                    root.moveLines(k === Qt.Key_Up ? -1 : 1); event.accepted = true; return
                }
                if ((k === Qt.Key_Return || k === Qt.Key_Enter) && !cmd && !ctl && !alt) {
                    // Auto-indent: keep the line's indent, one more after "(" or BEGIN.
                    const t = text, pos = selectionStart
                    const ls = t.lastIndexOf("\n", pos - 1) + 1
                    const line = t.substring(ls, pos)
                    let ind = /^[ \t]*/.exec(line)[0]
                    if (/(\(|\bbegin)\s*$/i.test(line)) ind += "    "
                    acSuppress = true
                    put("\n" + ind)
                    event.accepted = true
                    return
                }
                if (k === Qt.Key_Backspace && !cmd && !alt && selectedText.length === 0) {
                    // Delete an empty auto-closed pair together.
                    const p = cursorPosition, prev = text.charAt(p - 1), next = text.charAt(p)
                    const pairs = { "(": ")", "[": "]", "'": "'", "\"": "\"" }
                    if (p > 0 && pairs[prev] !== undefined && pairs[prev] === next) {
                        SqlEditorOps.replaceRange(textDocument, p - 1, p + 1, "")
                        event.accepted = true
                    }
                    return
                }
                // Auto-closing pairs, typing over an existing closer.
                const ch = event.text
                if (ch.length === 1 && !cmd && !ctl) {
                    const p = cursorPosition, next = text.charAt(p), prev = text.charAt(p - 1)
                    const closers = ")]'\""
                    if (selectedText.length === 0 && closers.indexOf(ch) >= 0 && next === ch) {
                        cursorPosition = p + 1
                        event.accepted = true
                        return
                    }
                    const open = { "(": ")", "[": "]", "'": "'", "\"": "\"" }[ch]
                    if (open !== undefined) {
                        if (selectedText.length > 0 && selectedText.indexOf("\n") < 0) {
                            const s = selectionStart, sel = selectedText
                            SqlEditorOps.replaceRange(textDocument, s, selectionEnd, ch + sel + open)
                            select(s + 1, s + 1 + sel.length)
                            event.accepted = true
                            return
                        }
                        const quote = ch === "'" || ch === "\""
                        const nextOk = next === "" || /[\s)\],;]/.test(next)
                        const prevOk = !quote || (!/[\w'"]/.test(prev) && SqlEditorOps.lexStateAt(text, p) === 0)
                        if (selectedText.length === 0 && nextOk && prevOk) {
                            put(ch + open, 1)
                            event.accepted = true
                        }
                    }
                }
            }

            SqlHighlighter {
                document: ed.textDocument
                keywordColor: Theme.sqlKeyword
                functionColor: Theme.sqlFunction
                stringColor: Theme.sqlString
                numberColor: Theme.sqlNumber
                commentColor: Theme.sqlComment
                identifierColor: Theme.sqlIdentifier
                operatorColor: Theme.sqlOperator
            }

            // Parameter hint above (or below, near the top) the caret.
            Rectangle {
                id: sigTip
                visible: ed.sigHtml !== "" && !acPopup.visible
                z: 10
                readonly property bool below: ed.cursorRectangle.y < height + 8
                x: Math.max(0, Math.min(ed.cursorRectangle.x - 12, ed.width - width - 4))
                y: below ? ed.cursorRectangle.y + ed.cursorRectangle.height + 4 : ed.cursorRectangle.y - height - 4
                width: Math.min(sigText.implicitWidth + 20, 560)
                height: sigText.implicitHeight + 12
                radius: Theme.radiusSm
                color: Theme.surface2
                border.color: Theme.borderStrong
                Text {
                    id: sigText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, 540)
                    textFormat: Text.RichText
                    text: ed.sigHtml
                    color: Theme.text
                    font.family: Theme.monoFamily; font.pixelSize: Theme.fontSm
                    wrapMode: Text.Wrap
                }
            }

            // Completion popup, anchored under the caret.
            Popup {
                id: acPopup
                parent: ed
                width: 380
                padding: 4
                implicitHeight: Math.min(acList.contentHeight + padding * 2, 236)
                closePolicy: Popup.CloseOnPressOutside
                background: Rectangle {
                    radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong
                }
                ListView {
                    id: acList
                    anchors.fill: parent
                    clip: true
                    model: ed.acItems
                    currentIndex: ed.acIndex
                    boundsBehavior: Flickable.StopAtBounds
                    highlightMoveDuration: 0
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: acDel
                        required property int index
                        required property var modelData
                        width: acList.width; height: 28
                        onClicked: { ed.acIndex = index; ed.acAccept() }
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: acDel.index === ed.acIndex ? Theme.accentSoft : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 8
                            Rectangle {
                                Layout.leftMargin: 4; Layout.alignment: Qt.AlignVCenter
                                width: 6; height: 6; radius: 3; color: root.host ? root.host.acColor(acDel.modelData.kind) : Theme.textFaint
                            }
                            Text {
                                Layout.fillWidth: true
                                text: acDel.modelData.text
                                color: Theme.text; font.family: Theme.monoFamily; font.pixelSize: Theme.fontSm
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.maximumWidth: 170
                                visible: text !== ""
                                text: acDel.modelData.detail
                                color: Theme.textFaint; font.family: Theme.monoFamily; font.pixelSize: Theme.fontXs
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.rightMargin: 6
                                text: acDel.modelData.kind
                                color: Theme.textFaint; font.pixelSize: Theme.fontXs
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- find / replace ----
    Rectangle {
        id: findBar
        visible: false
        z: 20
        anchors { top: parent.top; right: parent.right; topMargin: 4; rightMargin: 14 }
        width: Math.min(parent.width - 24, 470)
        height: findCol.implicitHeight + 12
        radius: Theme.radius
        color: Theme.surface2
        border.color: Theme.borderStrong

        property bool replaceMode: false
        property bool matchCase: false
        property bool wholeWord: false
        property bool useRegex: false
        property var matches: []
        property int current: -1

        function refresh() {
            matches = SqlEditorOps.findAll(ed.text, findField.text, matchCase, wholeWord, useRegex)
            if (matches.length === 0) { current = -1; return }
            // Keep the current match near the caret.
            let c = 0
            const from = ed.selectionStart
            for (let i = 0; i < matches.length; i++) if (matches[i].start >= from) { c = i; break }
            current = Math.min(c, matches.length - 1)
        }
        function go(step) {
            if (matches.length === 0) refresh()
            if (matches.length === 0) return
            const from = step > 0 ? ed.selectionEnd : ed.selectionStart
            let i
            if (step > 0) {
                i = matches.findIndex(m => m.start >= from)
                if (i < 0) i = 0
            } else {
                i = -1
                for (let k = matches.length - 1; k >= 0; k--) if (matches[k].end <= from) { i = k; break }
                if (i < 0) i = matches.length - 1
            }
            current = i
            ed.select(matches[i].start, matches[i].end)
        }
        function replaceOne() {
            const m = current >= 0 ? matches[current] : null
            if (m && ed.selectionStart === m.start && ed.selectionEnd === m.end) {
                const w = SqlEditorOps.expandReplacement(ed.text, m.start, m.end, findField.text,
                                                         replaceField.text, matchCase, useRegex)
                const at = SqlEditorOps.replaceRange(ed.textDocument, m.start, m.end, w)
                ed.cursorPosition = at
                refresh()
            }
            go(1)
        }
        function replaceAll() {
            const n = SqlEditorOps.replaceAllMatches(ed.textDocument, findField.text, replaceField.text,
                                                     matchCase, wholeWord, useRegex)
            refresh()
            countLabel.flash = n > 0 ? qsTr("%n replaced", "", n) : ""
        }

        component OptToggle: AbstractButton {
            id: ot
            property string label
            property string tip
            checkable: true
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            implicitWidth: 26; implicitHeight: 24
            ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: tip
            background: Rectangle {
                radius: Theme.radiusSm
                color: ot.checked ? Theme.accentSoft : (ot.hovered ? Theme.hover : "transparent")
                border.color: ot.checked ? Theme.accent : "transparent"
            }
            contentItem: Text {
                text: ot.label; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                color: ot.checked ? Theme.accent : Theme.textDim
                font.family: Theme.monoFamily; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
            }
        }
        component BarButton: AbstractButton {
            id: bb
            property string label
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            implicitHeight: 24
            implicitWidth: Math.max(24, bbText.implicitWidth + 12)
            background: Rectangle { radius: Theme.radiusSm; color: bb.hovered ? Theme.hover : "transparent" }
            contentItem: Text {
                id: bbText
                text: bb.label; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                color: bb.enabled ? Theme.text : Theme.textFaint; font.pixelSize: Theme.fontSm
            }
        }

        ColumnLayout {
            id: findCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                TextField {
                    id: findField
                    Layout.fillWidth: true
                    implicitHeight: 26
                    placeholderText: qsTr("Find")
                    placeholderTextColor: Theme.textFaint
                    color: Theme.text; font.pixelSize: Theme.fontSm
                    background: Rectangle {
                        radius: Theme.radiusSm; color: Theme.bg
                        border.color: findField.activeFocus ? Theme.accent : Theme.border
                    }
                    onTextChanged: {
                        countLabel.flash = ""
                        findBar.refresh()
                        if (findBar.current >= 0)
                            ed.select(findBar.matches[findBar.current].start, findBar.matches[findBar.current].end)
                    }
                    Keys.onReturnPressed: (e) => findBar.go((e.modifiers & Qt.ShiftModifier) ? -1 : 1)
                    Keys.onEnterPressed: (e) => findBar.go((e.modifiers & Qt.ShiftModifier) ? -1 : 1)
                    Keys.onEscapePressed: root.closeFind()
                }
                OptToggle { label: "Aa"; tip: qsTr("Match case"); checked: findBar.matchCase; onToggled: { findBar.matchCase = checked; findBar.refresh() } }
                OptToggle { label: "W"; tip: qsTr("Whole word"); checked: findBar.wholeWord; onToggled: { findBar.wholeWord = checked; findBar.refresh() } }
                OptToggle { label: ".*"; tip: qsTr("Regular expression"); checked: findBar.useRegex; onToggled: { findBar.useRegex = checked; findBar.refresh() } }
                Text {
                    id: countLabel
                    property string flash: ""
                    Layout.preferredWidth: 72
                    horizontalAlignment: Text.AlignHCenter
                    text: flash !== "" ? flash
                        : findField.text === "" ? ""
                        : findBar.matches.length === 0 ? qsTr("No results")
                        : qsTr("%1 of %2").arg(findBar.current + 1).arg(findBar.matches.length)
                    color: findBar.matches.length === 0 && findField.text !== "" ? Theme.danger : Theme.textDim
                    font.pixelSize: Theme.fontXs
                }
                BarButton { label: "↑"; onClicked: findBar.go(-1); ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Previous (Shift+Enter)") }
                BarButton { label: "↓"; onClicked: findBar.go(1); ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Next (Enter)") }
                BarButton { label: "✕"; onClicked: root.closeFind() }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: findBar.replaceMode
                spacing: 4
                TextField {
                    id: replaceField
                    Layout.fillWidth: true
                    implicitHeight: 26
                    placeholderText: qsTr("Replace")
                    placeholderTextColor: Theme.textFaint
                    color: Theme.text; font.pixelSize: Theme.fontSm
                    background: Rectangle {
                        radius: Theme.radiusSm; color: Theme.bg
                        border.color: replaceField.activeFocus ? Theme.accent : Theme.border
                    }
                    Keys.onReturnPressed: findBar.replaceOne()
                    Keys.onEnterPressed: findBar.replaceOne()
                    Keys.onEscapePressed: root.closeFind()
                }
                BarButton { label: qsTr("Replace"); enabled: findBar.matches.length > 0; onClicked: findBar.replaceOne() }
                BarButton { label: qsTr("All"); enabled: findBar.matches.length > 0; onClicked: findBar.replaceAll() }
            }
        }
    }
}
