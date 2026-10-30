.pragma library

// Editor IntelliSense for the SQL console: context-aware completion over the
// session's schema cache (SqlSession.schema), parameter hints for routines, and
// snippets. Pure functions over the editor text; the editor supplies the
// current statement's bounds so completion only looks at that statement.

var KEYWORDS = [
    "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "JOIN", "INNER JOIN",
    "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON", "AS", "AND", "OR", "NOT",
    "IN", "LIKE", "BETWEEN", "IS NULL", "IS NOT NULL", "INSERT INTO", "VALUES", "UPDATE",
    "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX", "DISTINCT", "TOP",
    "LIMIT", "OFFSET", "UNION", "UNION ALL", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END",
    "ASC", "DESC", "WITH", "EXEC", "CALL", "RETURNING", "INTO", "USING", "BEGIN", "COMMIT",
    "ROLLBACK", "DECLARE", "PRINT", "TRUNCATE TABLE"
]
var FUNCTIONS = [
    "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "CONVERT", "ROUND",
    "ABS", "LEN", "LENGTH", "SUBSTRING", "REPLACE", "TRIM", "LOWER", "UPPER", "CONCAT", "NOW",
    "GETDATE", "CURRENT_TIMESTAMP", "DATEADD", "DATEDIFF", "ROW_NUMBER", "RANK", "DENSE_RANK",
    "ISNULL", "STRING_AGG", "DATE_TRUNC", "EXTRACT", "TO_CHAR", "FORMAT", "IIF", "OVER"
]

// $1.. are tab stops in order, $0 the final caret. Bodies may differ by engine.
var SNIPPETS = [
    { trigger: "sel", label: "SELECT TOP 100 * FROM",
      mssql: "SELECT TOP 100 *\nFROM $1$0", postgres: "SELECT *\nFROM $1\nLIMIT 100$0" },
    { trigger: "ins", label: "INSERT INTO … VALUES",
      mssql: "INSERT INTO $1 ($2)\nVALUES ($3);$0" },
    { trigger: "upd", label: "UPDATE … SET … WHERE",
      mssql: "UPDATE $1\nSET $2 = $3\nWHERE $4;$0" },
    { trigger: "del", label: "DELETE FROM … WHERE",
      mssql: "DELETE FROM $1\nWHERE $2;$0" },
    { trigger: "cte", label: "WITH cte AS (…)",
      mssql: "WITH cte AS (\n    SELECT $1\n    FROM $2\n)\nSELECT *\nFROM cte;$0" },
    { trigger: "tran", label: "BEGIN TRAN … COMMIT",
      mssql: "BEGIN TRAN;\n\n$1\n\nCOMMIT TRAN;$0", postgres: "BEGIN;\n\n$1\n\nCOMMIT;$0" },
    { trigger: "ifex", label: "IF EXISTS (…) BEGIN … END",
      mssql: "IF EXISTS (SELECT 1 FROM $1 WHERE $2)\nBEGIN\n    $3\nEND$0",
      postgres: "DO $$\nBEGIN\n    IF EXISTS (SELECT 1 FROM $1 WHERE $2) THEN\n        $3\n    END IF;\nEND $$;$0" }
]

// Expands a snippet body: returns {text, stops: [offsets in visit order]}.
function expandSnippet(snip, engine) {
    var body = (engine === "postgres" && snip.postgres) ? snip.postgres : snip.mssql
    var text = "", marks = []
    for (var i = 0; i < body.length; i++) {
        var c = body.charAt(i)
        if (c === "$" && /[0-9]/.test(body.charAt(i + 1))) {
            marks.push({ n: parseInt(body.charAt(i + 1)), at: text.length })
            i++
            continue
        }
        text += c
    }
    marks.sort(function (a, b) {
        var x = a.n === 0 ? 99 : a.n, y = b.n === 0 ? 99 : b.n
        return x - y
    })
    return { text: text, stops: marks.map(function (m) { return m.at }) }
}

function unquote(s) {
    return s.replace(/^\[|\]$/g, "").replace(/^"|"$/g, "")
}
function bareName(full) {
    var i = full.indexOf(".")
    return i >= 0 ? full.substring(i + 1) : full
}
function schemaOf(full) {
    var i = full.indexOf(".")
    return i >= 0 ? full.substring(0, i) : ""
}
function defaultSchema(engine) { return engine === "postgres" ? "public" : "dbo" }
// How a table is inserted: bare when in the default schema, else qualified.
function displayName(full, engine) {
    return schemaOf(full).toLowerCase() === defaultSchema(engine) ? bareName(full) : full
}

// Blanks strings and comments (same length) so regexes over a statement don't
// match inside them.
function stripLiterals(t) {
    var out = "", i = 0, n = t.length
    while (i < n) {
        var c = t.charAt(i), c2 = t.charAt(i + 1)
        if (c === "-" && c2 === "-") {
            while (i < n && t.charAt(i) !== "\n") { out += " "; i++ }
        } else if (c === "/" && c2 === "*") {
            var e = t.indexOf("*/", i + 2)
            e = e < 0 ? n : e + 2
            while (i < e) { out += t.charAt(i) === "\n" ? "\n" : " "; i++ }
        } else if (c === "'") {
            out += "'"; i++
            while (i < n) {
                if (t.charAt(i) === "'") {
                    if (t.charAt(i + 1) === "'") { out += "  "; i += 2; continue }
                    break
                }
                out += t.charAt(i) === "\n" ? "\n" : " "; i++
            }
            if (i < n) { out += "'"; i++ }
        } else {
            out += c; i++
        }
    }
    return out
}

// Resolves a name (bare, schema.name, quoted) to a schema.tables key.
function resolveTable(schema, name, engine) {
    var tables = (schema && schema.tables) || {}
    var parts = name.split(".").map(unquote)
    var want = parts.slice(-2).join(".").toLowerCase()
    var bare = parts[parts.length - 1].toLowerCase()
    var hit = ""
    for (var k in tables) {
        var kl = k.toLowerCase()
        if (kl === want) return k
        if (parts.length === 1 && bareName(kl) === bare) {
            if (schemaOf(kl) === defaultSchema(engine)) return k
            if (!hit) hit = k
        }
    }
    return hit
}
function resolveRoutine(schema, name, engine) {
    var routines = (schema && schema.routines) || {}
    var parts = name.split(".").map(unquote)
    var want = parts.slice(-2).join(".").toLowerCase()
    var bare = parts[parts.length - 1].toLowerCase()
    var hit = ""
    for (var k in routines) {
        var kl = k.toLowerCase()
        if (kl === want) return k
        if (parts.length === 1 && bareName(kl) === bare) {
            if (schemaOf(kl) === defaultSchema(engine)) return k
            if (!hit) hit = k
        }
    }
    return hit
}

var IDENT = "(?:\\[[^\\]]+\\]|\"[^\"]+\"|[A-Za-z_#@][\\w$#@]*)"
var RESERVED = /^(where|on|join|inner|left|right|full|cross|outer|group|order|having|union|set|values|select|from|as|with|limit|offset|using|natural|lateral|apply|into|for|option|when|then|and|or|returning|output)$/i

// Scope of a statement: tables it references (with aliases) and its CTEs.
// Returns {refs: [{table (schema key or cte name), alias, cte}], ctes: {name: [cols]}}.
function statementScope(stmt, schema, engine) {
    var s = stripLiterals(stmt)
    var ctes = {}
    var cteRe = new RegExp("(?:\\bwith\\s+(?:recursive\\s+)?|,\\s*)(" + IDENT + ")\\s*(?:\\(([^)]*)\\))?\\s*as\\s*\\(", "gi")
    var m
    while ((m = cteRe.exec(s)) !== null) {
        var name = unquote(m[1])
        var cols = []
        if (m[2]) {
            cols = m[2].split(",").map(function (x) { return unquote(x.trim()) }).filter(function (x) { return x })
        } else {
            // Derive from the CTE's select list: each item's alias or last name.
            var open = cteRe.lastIndex - 1, depth = 0, end = s.length
            for (var i = open; i < s.length; i++) {
                if (s.charAt(i) === "(") depth++
                else if (s.charAt(i) === ")") { depth--; if (depth === 0) { end = i; break } }
            }
            var body = s.substring(open + 1, end)
            var sel = /^\s*select\s+(?:distinct\s+)?(?:top\s+\(?\d+\)?\s+)?([\s\S]*?)\bfrom\b/i.exec(body)
            if (sel) {
                var items = [], d = 0, cur = ""
                for (var j = 0; j < sel[1].length; j++) {
                    var ch = sel[1].charAt(j)
                    if (ch === "(") d++
                    if (ch === ")") d--
                    if (ch === "," && d === 0) { items.push(cur); cur = "" } else cur += ch
                }
                items.push(cur)
                for (var q = 0; q < items.length; q++) {
                    var it = items[q].trim()
                    var am = new RegExp("(?:\\bas\\s+)?(" + IDENT + ")\\s*$", "i").exec(it)
                    if (am && it !== "*") cols.push(unquote(am[1]))
                }
            }
        }
        ctes[name.toLowerCase()] = { name: name, columns: cols }
    }

    var refs = []
    var refRe = new RegExp("(\\bfrom|\\bjoin|\\bupdate|\\binto|\\bapply|,)\\s+(" + IDENT + "(?:\\s*\\.\\s*" + IDENT + "){0,2})(?:\\s+(?:as\\s+)?(" + IDENT + "))?", "gi")
    while ((m = refRe.exec(s)) !== null) {
        var raw = m[2].replace(/\s+/g, "")
        var alias = m[3] && !RESERVED.test(m[3]) ? unquote(m[3]) : ""
        var cte = ctes[unquote(raw).toLowerCase()]
        if (cte) {
            refs.push({ table: cte.name, alias: alias, cte: true, at: m.index })
            continue
        }
        var key = resolveTable(schema, raw, engine)
        if (!key) continue
        refs.push({ table: key, alias: alias, cte: false, at: m.index })
    }
    return { refs: refs, ctes: ctes }
}

function columnsOf(ref, scope, schema) {
    if (ref.cte) {
        var c = scope.ctes[ref.table.toLowerCase()]
        return c ? c.columns.map(function (n) { return { name: n, type: "" } }) : []
    }
    var t = schema.tables[ref.table]
    return t ? (t.columns || []) : []
}

// Fuzzy score: 0 prefix, 1 word-part prefix, 2 substring, 3 subsequence; -1 none.
function score(name, p) {
    if (!p) return 0
    var n = name.toLowerCase()
    if (n.indexOf(p) === 0) return 0
    var at = n.indexOf(p)
    if (at > 0 && /[_.\s]/.test(n.charAt(at - 1))) return 1
    if (at > 0) return 2
    var j = 0
    for (var i = 0; i < n.length && j < p.length; i++)
        if (n.charAt(i) === p.charAt(j)) j++
    return j === p.length && p.length >= 2 ? 3 : -1
}

// Lower-case last clause keyword before `pos` in the (literal-stripped)
// statement, at the outermost depth the cursor is in.
function clauseBefore(s, pos) {
    var re = /\b(select|from|join|where|on|group\s+by|order\s+by|having|set|values|exec|execute|call|into|update|delete|returning|using|when|then|by)\b/gi
    var depthAt = 0
    for (var i = 0; i < pos; i++) {
        if (s.charAt(i) === "(") depthAt++
        else if (s.charAt(i) === ")") depthAt--
    }
    var last = "", m, d = 0, k = 0
    while ((m = re.exec(s)) !== null && m.index < pos) {
        for (; k < m.index; k++) {
            if (s.charAt(k) === "(") d++
            else if (s.charAt(k) === ")") d--
        }
        if (d === depthAt) last = m[1].toLowerCase().replace(/\s+/g, " ")
    }
    return last
}

// Completion at `pos` of `text`. `stmt` = {start, end} of the statement around
// the caret. Returns {start, items: [{text, insert, kind, detail, snippet}]}
// or null when nothing fits.
function complete(text, pos, stmt, schema, engine, manual) {
    schema = schema || {}
    var tables = schema.tables || {}, routines = schema.routines || {}
    var i = pos
    while (i > 0 && /[A-Za-z0-9_.$#@\[\]"]/.test(text.charAt(i - 1))) i--
    var token = text.substring(i, pos)
    if (/^\d+$/.test(token)) return null
    var dot = token.lastIndexOf(".")
    var qualifier = dot >= 0 ? token.substring(0, dot) : ""
    var partial = unquote(dot >= 0 ? token.substring(dot + 1) : token).replace(/^\[/, "")
    var start = dot >= 0 ? i + dot + 1 : i
    if (!manual && qualifier === "" && partial.length < 1) return null

    var stmtText = text.substring(stmt.start, Math.max(stmt.end, pos))
    var rel = i - stmt.start
    var stripped = stripLiterals(stmtText)
    var scope = statementScope(stmtText, schema, engine)
    var before = stripped.substring(0, rel)
    var pw = /([A-Za-z_]+)\s*$/.exec(before)
    var prevWord = pw ? pw[1].toLowerCase() : ""
    var prevChar = before.replace(/\s+$/, "").slice(-1)
    var clause = clauseBefore(stripped, rel)
    var p = partial.toLowerCase()
    var out = []
    var add = function (txt, kind, detail, prio, ins) {
        var sc = score(txt, p)
        if (sc < 0) return
        out.push({ text: txt, insert: ins || txt, kind: kind, detail: detail || "", rank: sc, prio: prio })
    }
    var addTables = function (prio) {
        for (var k in tables) add(displayName(k, engine), tables[k].type, "", prio)
        for (var c in scope.ctes) add(scope.ctes[c].name, "cte", "", prio)
    }
    var addScopeColumns = function (prio) {
        var seen = {}
        for (var r = 0; r < scope.refs.length; r++) {
            var ref = scope.refs[r]
            var cols = columnsOf(ref, scope, schema)
            var owner = ref.alias || bareName(ref.table)
            for (var q = 0; q < cols.length; q++) {
                var key = cols[q].name.toLowerCase()
                if (seen[key]) continue
                seen[key] = true
                add(cols[q].name, "column", (cols[q].type ? cols[q].type + " · " : "") + owner, prio)
            }
        }
        return Object.keys(seen).length
    }
    // Aliases (or bare table names) in scope, so typing `c` offers `c.` first.
    var addScopeOwners = function (prio) {
        for (var r = 0; r < scope.refs.length; r++) {
            var ref = scope.refs[r]
            var owner = ref.alias || bareName(ref.table)
            var t = ref.cte ? "cte" : ((tables[ref.table] && tables[ref.table].type) || "table")
            add(owner, t, ref.alias ? "alias · " + bareName(ref.table) : "", prio)
        }
    }

    if (qualifier !== "") {
        // alias.col / table.col / schema.object
        var ql = unquote(qualifier.split(".").pop()).toLowerCase()
        var hit = null
        for (var r = 0; r < scope.refs.length && !hit; r++) {
            var ref = scope.refs[r]
            if ((ref.alias && ref.alias.toLowerCase() === ql) || bareName(ref.table).toLowerCase() === ql
                || ref.table.toLowerCase() === qualifier.toLowerCase())
                hit = ref
        }
        if (!hit) {
            var key = resolveTable(schema, qualifier, engine)
            if (key) hit = { table: key, alias: "", cte: false }
            else if (scope.ctes[ql]) hit = { table: scope.ctes[ql].name, alias: "", cte: true }
        }
        if (hit) {
            var cols = columnsOf(hit, scope, schema)
            for (var q = 0; q < cols.length; q++) add(cols[q].name, "column", cols[q].type, 0)
        } else {
            var pre = unquote(qualifier).toLowerCase() + "."
            for (var t in tables)
                if (t.toLowerCase().indexOf(pre) === 0) add(bareName(t), tables[t].type, "", 0)
            for (var rt in routines)
                if (rt.toLowerCase().indexOf(pre) === 0) add(bareName(rt), routines[rt].type, "", 1)
        }
    } else if (["from", "join", "into", "update", "table", "apply"].indexOf(prevWord) !== -1
               || (prevChar === "," && clause === "from")) {
        addTables(0)
    } else if (["exec", "execute", "call"].indexOf(prevWord) !== -1) {
        for (var rk in routines)
            if (prevWord === "call" || routines[rk].type === "procedure")
                add(displayName(rk, engine), routines[rk].type, "", 0)
    } else {
        // Join conditions from foreign keys right after JOIN ... ON.
        if (prevWord === "on" && scope.refs.length >= 2) {
            var fks = schema.fks || []
            var joined = null
            for (var z = scope.refs.length - 1; z >= 0; z--)
                if (scope.refs[z].at < rel) { joined = scope.refs[z]; break }
            if (joined) {
                var nameOf = function (ref) { return ref.alias || bareName(ref.table) }
                for (var f = 0; f < fks.length; f++) {
                    var fk = fks[f]
                    for (var o = 0; o < scope.refs.length; o++) {
                        var other = scope.refs[o]
                        if (other === joined || other.at > joined.at) continue
                        var a = null, b = null
                        if (fk.from === joined.table && fk.to === other.table) { a = joined; b = other }
                        else if (fk.to === joined.table && fk.from === other.table) { a = other; b = joined }
                        if (!a) continue
                        var conds = []
                        for (var x = 0; x < fk.fromCols.length; x++)
                            conds.push(nameOf(a) + "." + fk.fromCols[x] + " = " + nameOf(b) + "." + fk.toCols[x])
                        var cond = conds.join(" AND ")
                        out.push({ text: cond, insert: cond, kind: "join", detail: "foreign key", rank: 0, prio: -1 })
                    }
                }
            }
        }
        var colCtx = ["select", "where", "on", "group by", "order by", "by", "having", "set", "when",
                      "then", "returning"].indexOf(clause) !== -1
        if (colCtx) {
            addScopeOwners(-1)
            addScopeColumns(0)
            for (var fi = 0; fi < FUNCTIONS.length; fi++) add(FUNCTIONS[fi], "function", "", 2)
            for (var ki = 0; ki < KEYWORDS.length; ki++) add(KEYWORDS[ki], "keyword", "", 3)
            if (clause === "select") addTables(4)
        } else {
            for (var ki2 = 0; ki2 < KEYWORDS.length; ki2++) add(KEYWORDS[ki2], "keyword", "", 1)
            addScopeOwners(2)
            addScopeColumns(2)
            for (var fi2 = 0; fi2 < FUNCTIONS.length; fi2++) add(FUNCTIONS[fi2], "function", "", 2)
            addTables(3)
        }
        // Snippets at the start of a statement (or anywhere outside a column list).
        if (p.length >= 2 && !colCtx)
            for (var si = 0; si < SNIPPETS.length; si++)
                if (SNIPPETS[si].trigger.indexOf(p) === 0)
                    out.push({ text: SNIPPETS[si].trigger, insert: "", kind: "snippet",
                               detail: SNIPPETS[si].label, rank: 0, prio: -1, snippet: SNIPPETS[si] })
    }

    out.sort(function (a, b) {
        return a.rank - b.rank || a.prio - b.prio || a.text.length - b.text.length
               || (a.text.toLowerCase() < b.text.toLowerCase() ? -1 : 1)
    })
    var uniq = [], seen2 = {}
    for (var u = 0; u < out.length; u++) {
        var key2 = out[u].kind + ":" + out[u].text
        if (seen2[key2]) continue
        seen2[key2] = true
        uniq.push(out[u])
    }
    // Hide a list whose only entry is exactly what is already typed.
    if (uniq.length === 1 && uniq[0].kind !== "snippet" && uniq[0].text.toLowerCase() === p && !manual)
        return null
    return uniq.length ? { start: start, items: uniq.slice(0, 40) } : null
}

// Parameter hint at `pos`: {name, params: [{name, type, dir}], index, html}
// for the routine call the caret is inside — name(…) or EXEC name args — or null.
function signature(text, pos, stmt, schema, engine) {
    var routines = (schema && schema.routines) || {}
    var s = stripLiterals(text.substring(stmt.start, pos))
    var depth = 0, commas = 0, open = -1
    for (var i = s.length - 1; i >= 0; i--) {
        var c = s.charAt(i)
        if (c === ")") depth++
        else if (c === "(") {
            if (depth === 0) { open = i; break }
            depth--
        } else if (c === "," && depth === 0) commas++
        else if (c === ";") break
    }
    var key = "", index = commas, named = ""
    if (open >= 0) {
        var nm = new RegExp("(" + IDENT + "(?:\\." + IDENT + ")?)\\s*$").exec(s.substring(0, open))
        if (nm) key = resolveRoutine(schema, nm[1], engine)
    }
    if (!key) {
        // EXEC proc arg, arg — commas counted at depth 0 after the name.
        var ex = new RegExp("^\\s*(?:exec|execute)\\s+(?:@\\w+\\s*=\\s*)?(" + IDENT + "(?:\\." + IDENT + ")?)\\s+([\\s\\S]*)$", "i").exec(s)
        if (!ex) return null
        key = resolveRoutine(schema, ex[1], engine)
        if (!key) return null
        var args = ex[2], d = 0
        index = 0
        for (var j = 0; j < args.length; j++) {
            var ch = args.charAt(j)
            if (ch === "(") d++
            else if (ch === ")") d--
            else if (ch === "," && d === 0) index++
        }
        var lastArg = args.split(",").pop()
        var na = /^\s*(@\w+)\s*=/.exec(lastArg)
        if (na) named = na[1].toLowerCase()
    }
    var r = routines[key]
    var params = (r.params || []).filter(function (p) { return !(engine === "postgres" && r.type === "function" && p.dir === "out") })
    if (named)
        for (var k = 0; k < params.length; k++)
            if (params[k].name.toLowerCase() === named) index = k
    var esc = function (t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    var parts = params.map(function (p, n) {
        var label = esc((p.name ? p.name + " " : "") + p.type + (p.dir === "out" ? " OUTPUT" : p.dir === "inout" ? " INOUT" : ""))
        return n === index ? "<b><u>" + label + "</u></b>" : label
    })
    return { name: key, params: params, index: index,
             html: esc(displayName(key, engine)) + "(" + (parts.length ? parts.join(", ") : "<i>no parameters</i>") + ")" }
}
