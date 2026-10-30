#include "SqlEditorOps.h"

#include <QRegularExpression>
#include <QSet>
#include <QTextCursor>
#include <QTextDocument>
#include <QVector>

#include <algorithm>

namespace {

QTextDocument* docOf(QQuickTextDocument* doc)
{
    return doc ? doc->textDocument() : nullptr;
}

// Replaces [start, end) as one undo step.
void editRange(QTextDocument* d, int start, int end, const QString& text)
{
    QTextCursor c(d);
    c.beginEditBlock();
    c.setPosition(start);
    c.setPosition(end, QTextCursor::KeepAnchor);
    c.insertText(text);
    c.endEditBlock();
}

QVariantMap sel(int start, int end)
{
    return { { QStringLiteral("start"), start }, { QStringLiteral("end"), end } };
}

// The whole lines a selection touches: [start, end) without the final newline.
// A selection ending right after a newline doesn't include the next line.
struct LineSpan
{
    int start = 0;
    int end = 0;
};

LineSpan lineSpan(const QString& all, int selStart, int selEnd)
{
    if (selEnd < selStart)
        std::swap(selStart, selEnd);
    selStart = std::clamp(selStart, 0, int(all.size()));
    selEnd = std::clamp(selEnd, 0, int(all.size()));
    if (selEnd > selStart && all.at(selEnd - 1) == QLatin1Char('\n'))
        --selEnd;
    LineSpan s;
    s.start = selStart > 0 ? int(all.lastIndexOf(QLatin1Char('\n'), selStart - 1)) + 1 : 0;
    s.end = int(all.indexOf(QLatin1Char('\n'), selEnd));
    if (s.end < 0)
        s.end = int(all.size());
    return s;
}

int leadingSpaces(const QString& line)
{
    int i = 0;
    while (i < line.size() && (line.at(i) == QLatin1Char(' ') || line.at(i) == QLatin1Char('\t')))
        ++i;
    return i;
}

// Walks SQL, calling `code(i)` for every character outside strings, quoted
// identifiers and comments. Returns the lexical state at `stopAt` (0 code,
// 1 string/identifier, 2 comment) when stopAt >= 0.
template <typename F>
int lexWalk(const QString& t, int stopAt, F code)
{
    enum { Code, Str, Dq, Br, Line, Block };
    int st = Code, depth = 0;
    const int n = int(t.size());
    for (int i = 0; i < n; ++i) {
        if (i == stopAt)
            return st == Code ? 0 : (st == Line || st == Block) ? 2 : 1;
        const QChar c = t.at(i);
        const QChar c2 = i + 1 < n ? t.at(i + 1) : QChar();
        switch (st) {
        case Code:
            if (c == QLatin1Char('\'')) st = Str;
            else if (c == QLatin1Char('"')) st = Dq;
            else if (c == QLatin1Char('-') && c2 == QLatin1Char('-')) { st = Line; ++i; }
            else if (c == QLatin1Char('/') && c2 == QLatin1Char('*')) { st = Block; depth = 1; ++i; }
            else code(i);
            break;
        case Str:
            if (c == QLatin1Char('\'')) { if (c2 == QLatin1Char('\'') && i + 1 != stopAt) ++i; else st = Code; }
            break;
        case Dq:
            if (c == QLatin1Char('"')) st = Code;
            break;
        case Br:
            if (c == QLatin1Char(']')) st = Code;
            break;
        case Line:
            if (c == QLatin1Char('\n')) st = Code;
            break;
        case Block:
            if (c == QLatin1Char('/') && c2 == QLatin1Char('*')) { ++depth; ++i; }
            else if (c == QLatin1Char('*') && c2 == QLatin1Char('/')) { if (--depth == 0) st = Code; ++i; }
            break;
        }
    }
    if (stopAt >= n)
        return st == Code ? 0 : (st == Line || st == Block) ? 2 : 1;
    return 0;
}

QRegularExpression buildFind(const QString& needle, bool caseSensitive, bool wholeWord, bool regex)
{
    QString pat = regex ? needle : QRegularExpression::escape(needle);
    if (wholeWord)
        pat = QStringLiteral("\\b(?:") + pat + QStringLiteral(")\\b");
    QRegularExpression re(pat, caseSensitive ? QRegularExpression::NoPatternOption
                                             : QRegularExpression::CaseInsensitiveOption);
    return re;
}

// Expands \0..\9 in a regex replacement from one match.
QString expand(const QRegularExpressionMatch& m, const QString& repl)
{
    QString out;
    for (int i = 0; i < repl.size(); ++i) {
        const QChar c = repl.at(i);
        if (c == QLatin1Char('\\') && i + 1 < repl.size()) {
            const QChar d = repl.at(i + 1);
            if (d.isDigit()) { out += m.captured(d.digitValue()); ++i; continue; }
            if (d == QLatin1Char('n')) { out += QLatin1Char('\n'); ++i; continue; }
            if (d == QLatin1Char('t')) { out += QLatin1Char('\t'); ++i; continue; }
            if (d == QLatin1Char('\\')) { out += QLatin1Char('\\'); ++i; continue; }
        }
        out += c;
    }
    return out;
}

} // namespace

int SqlEditorOps::replaceRange(QQuickTextDocument* doc, int start, int end, const QString& text)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return start;
    const int len = d->characterCount() - 1;
    start = std::clamp(start, 0, len);
    end = std::clamp(end, start, len);
    editRange(d, start, end, text);
    return start + int(text.size());
}

void SqlEditorOps::replaceAll(QQuickTextDocument* doc, const QString& text)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return;
    editRange(d, 0, d->characterCount() - 1, text);
}

QVariantMap SqlEditorOps::toggleComment(QQuickTextDocument* doc, int selStart, int selEnd)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return sel(selStart, selEnd);
    const QString all = d->toPlainText();
    const LineSpan sp = lineSpan(all, selStart, selEnd);
    QStringList lines = all.mid(sp.start, sp.end - sp.start).split(QLatin1Char('\n'));
    bool allCommented = true, anyCode = false;
    int minIndent = INT_MAX;
    for (const QString& l : std::as_const(lines)) {
        if (l.trimmed().isEmpty())
            continue;
        anyCode = true;
        const int ind = leadingSpaces(l);
        minIndent = std::min(minIndent, ind);
        if (!QStringView(l).mid(ind).startsWith(QLatin1String("--")))
            allCommented = false;
    }
    if (!anyCode)
        return sel(selStart, selEnd);
    int firstDelta = 0;
    for (int k = 0; k < lines.size(); ++k) {
        QString& l = lines[k];
        if (l.trimmed().isEmpty())
            continue;
        int delta;
        if (allCommented) {
            const int ind = leadingSpaces(l);
            const int cut = QStringView(l).mid(ind).startsWith(QLatin1String("-- ")) ? 3 : 2;
            l.remove(ind, cut);
            delta = -cut;
        } else {
            l.insert(minIndent, QStringLiteral("-- "));
            delta = 3;
        }
        if (k == 0)
            firstDelta = delta;
    }
    const QString text = lines.join(QLatin1Char('\n'));
    editRange(d, sp.start, sp.end, text);
    if (selStart == selEnd) {
        const int caret = std::max(sp.start, selStart + firstDelta);
        return sel(caret, caret);
    }
    return sel(sp.start, sp.start + int(text.size()));
}

QVariantMap SqlEditorOps::duplicateLines(QQuickTextDocument* doc, int selStart, int selEnd)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return sel(selStart, selEnd);
    const QString all = d->toPlainText();
    const LineSpan sp = lineSpan(all, selStart, selEnd);
    const QString block = all.mid(sp.start, sp.end - sp.start);
    editRange(d, sp.end, sp.end, QLatin1Char('\n') + block);
    const int shift = int(block.size()) + 1;
    return sel(selStart + shift, selEnd + shift);
}

QVariantMap SqlEditorOps::moveLines(QQuickTextDocument* doc, int selStart, int selEnd, int dir)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return sel(selStart, selEnd);
    const QString all = d->toPlainText();
    const LineSpan sp = lineSpan(all, selStart, selEnd);
    const QString block = all.mid(sp.start, sp.end - sp.start);
    if (dir < 0) {
        if (sp.start == 0)
            return sel(selStart, selEnd);
        const int prevStart = sp.start >= 2 ? int(all.lastIndexOf(QLatin1Char('\n'), sp.start - 2)) + 1 : 0;
        const QString prev = all.mid(prevStart, sp.start - 1 - prevStart);
        editRange(d, prevStart, sp.end, block + QLatin1Char('\n') + prev);
        const int shift = int(prev.size()) + 1;
        return sel(selStart - shift, selEnd - shift);
    }
    if (sp.end >= all.size())
        return sel(selStart, selEnd);
    int nextEnd = int(all.indexOf(QLatin1Char('\n'), sp.end + 1));
    if (nextEnd < 0)
        nextEnd = int(all.size());
    const QString next = all.mid(sp.end + 1, nextEnd - sp.end - 1);
    editRange(d, sp.start, nextEnd, next + QLatin1Char('\n') + block);
    const int shift = int(next.size()) + 1;
    return sel(selStart + shift, selEnd + shift);
}

QVariantMap SqlEditorOps::indentLines(QQuickTextDocument* doc, int selStart, int selEnd, bool outdent)
{
    QTextDocument* d = docOf(doc);
    if (!d)
        return sel(selStart, selEnd);
    if (selEnd < selStart)
        std::swap(selStart, selEnd);
    const QString all = d->toPlainText();
    const LineSpan sp = lineSpan(all, selStart, selEnd);
    QStringList lines = all.mid(sp.start, sp.end - sp.start).split(QLatin1Char('\n'));
    int firstDelta = 0, total = 0;
    for (int k = 0; k < lines.size(); ++k) {
        QString& l = lines[k];
        int delta = 0;
        if (outdent) {
            int cut = 0;
            if (l.startsWith(QLatin1Char('\t')))
                cut = 1;
            else
                while (cut < 4 && cut < l.size() && l.at(cut) == QLatin1Char(' '))
                    ++cut;
            l.remove(0, cut);
            delta = -cut;
        } else if (!l.trimmed().isEmpty() || lines.size() == 1) {
            l.prepend(QStringLiteral("    "));
            delta = 4;
        }
        if (k == 0)
            firstDelta = delta;
        total += delta;
    }
    const QString text = lines.join(QLatin1Char('\n'));
    if (total == 0)
        return sel(selStart, selEnd);
    editRange(d, sp.start, sp.end, text);
    return sel(std::max(sp.start, selStart + firstDelta), std::max(sp.start, selEnd + total));
}

QVariantList SqlEditorOps::findAll(const QString& text, const QString& needle, bool caseSensitive,
                                   bool wholeWord, bool regex) const
{
    QVariantList out;
    if (needle.isEmpty())
        return out;
    const QRegularExpression re = buildFind(needle, caseSensitive, wholeWord, regex);
    if (!re.isValid())
        return out;
    auto it = re.globalMatch(text);
    while (it.hasNext()) {
        const auto m = it.next();
        if (m.capturedLength() == 0)
            continue;
        out.append(sel(int(m.capturedStart()), int(m.capturedEnd())));
    }
    return out;
}

QString SqlEditorOps::expandReplacement(const QString& text, int start, int end, const QString& needle,
                                        const QString& replacement, bool caseSensitive, bool regex) const
{
    if (!regex)
        return replacement;
    const QRegularExpression re = buildFind(needle, caseSensitive, false, true);
    const auto m = re.match(text, start);
    if (!m.hasMatch() || m.capturedStart() != start || m.capturedEnd() != end)
        return replacement;
    return expand(m, replacement);
}

int SqlEditorOps::replaceAllMatches(QQuickTextDocument* doc, const QString& needle,
                                    const QString& replacement, bool caseSensitive,
                                    bool wholeWord, bool regex)
{
    QTextDocument* d = docOf(doc);
    if (!d || needle.isEmpty())
        return 0;
    const QRegularExpression re = buildFind(needle, caseSensitive, wholeWord, regex);
    if (!re.isValid())
        return 0;
    struct Hit { int start, end; QString with; };
    QVector<Hit> hits;
    auto it = re.globalMatch(d->toPlainText());
    while (it.hasNext()) {
        const auto m = it.next();
        if (m.capturedLength() == 0)
            continue;
        hits.append({ int(m.capturedStart()), int(m.capturedEnd()), regex ? expand(m, replacement) : replacement });
    }
    if (hits.isEmpty())
        return 0;
    // One edit block, applied back to front so earlier offsets stay valid.
    QTextCursor c(d);
    c.beginEditBlock();
    for (int i = int(hits.size()) - 1; i >= 0; --i) {
        c.setPosition(hits.at(i).start);
        c.setPosition(hits.at(i).end, QTextCursor::KeepAnchor);
        c.insertText(hits.at(i).with);
    }
    c.endEditBlock();
    return int(hits.size());
}

int SqlEditorOps::matchBracket(const QString& text, int pos) const
{
    if (pos < 0 || pos >= text.size())
        return -1;
    const QChar c = text.at(pos);
    if (c != QLatin1Char('(') && c != QLatin1Char(')') && c != QLatin1Char('[') && c != QLatin1Char(']'))
        return -1;
    if (lexStateAt(text, pos) != 0)
        return -1;
    // Pair every code bracket with a stack; brackets inside literals are skipped.
    QVector<int> stack;
    int found = -1;
    lexWalk(text, -1, [&](int i) {
        if (found >= 0)
            return;
        const QChar ch = text.at(i);
        if (ch == QLatin1Char('(') || ch == QLatin1Char('[')) {
            stack.append(i);
        } else if (ch == QLatin1Char(')') || ch == QLatin1Char(']')) {
            if (stack.isEmpty())
                return;
            const int open = stack.takeLast();
            const QChar want = ch == QLatin1Char(')') ? QLatin1Char('(') : QLatin1Char('[');
            if (text.at(open) != want)
                return;
            if (open == pos)
                found = i;
            else if (i == pos)
                found = open;
        }
    });
    return found;
}

int SqlEditorOps::lexStateAt(const QString& text, int pos) const
{
    return lexWalk(text, std::clamp(pos, 0, int(text.size())), [](int) {});
}

// ---- formatter ----

namespace {

struct Tok
{
    enum Kind { Word, Number, String, Quoted, LineComment, BlockComment, Op, Open, Close, Comma, Semi, Dot };
    Kind kind;
    QString text;
    int newlinesBefore = 0;
    QString upper() const { return text.toUpper(); }
};

QVector<Tok> tokenize(const QString& s, bool pg)
{
    QVector<Tok> out;
    const int n = int(s.size());
    int i = 0, nl = 0;
    const auto push = [&](Tok::Kind k, int from, int to) {
        out.append({ k, s.mid(from, to - from), nl });
        nl = 0;
    };
    const auto isWord = [](QChar c) {
        return c.isLetterOrNumber() || c == QLatin1Char('_') || c == QLatin1Char('@')
               || c == QLatin1Char('#') || c == QLatin1Char('$');
    };
    while (i < n) {
        const QChar c = s.at(i);
        const QChar c2 = i + 1 < n ? s.at(i + 1) : QChar();
        if (c.isSpace()) {
            if (c == QLatin1Char('\n'))
                ++nl;
            ++i;
            continue;
        }
        const int st = i;
        if (c == QLatin1Char('-') && c2 == QLatin1Char('-')) {
            while (i < n && s.at(i) != QLatin1Char('\n'))
                ++i;
            push(Tok::LineComment, st, i);
        } else if (c == QLatin1Char('/') && c2 == QLatin1Char('*')) {
            int depth = 1;
            i += 2;
            while (i < n && depth > 0) {
                if (s.at(i) == QLatin1Char('/') && i + 1 < n && s.at(i + 1) == QLatin1Char('*')) { ++depth; i += 2; }
                else if (s.at(i) == QLatin1Char('*') && i + 1 < n && s.at(i + 1) == QLatin1Char('/')) { --depth; i += 2; }
                else ++i;
            }
            push(Tok::BlockComment, st, i);
        } else if (c == QLatin1Char('\'')
                   || (c2 == QLatin1Char('\'') && QStringLiteral("NnEeXxBb").contains(c)
                       && (st == 0 || !isWord(s.at(st - 1))))) {
            i += c == QLatin1Char('\'') ? 1 : 2;
            while (i < n) {
                if (s.at(i) == QLatin1Char('\'')) {
                    if (i + 1 < n && s.at(i + 1) == QLatin1Char('\'')) { i += 2; continue; }
                    ++i;
                    break;
                }
                ++i;
            }
            push(Tok::String, st, i);
        } else if (c == QLatin1Char('"') || (c == QLatin1Char('[') && !pg)) {
            const QChar close = c == QLatin1Char('"') ? QLatin1Char('"') : QLatin1Char(']');
            ++i;
            while (i < n) {
                if (s.at(i) == close) {
                    if (i + 1 < n && s.at(i + 1) == close) { i += 2; continue; }
                    ++i;
                    break;
                }
                ++i;
            }
            push(Tok::Quoted, st, i);
        } else if (pg && c == QLatin1Char('$') && !(c2.isDigit())) {
            // $tag$ ... $tag$ dollar quoting.
            int j = i + 1;
            while (j < n && (s.at(j).isLetterOrNumber() || s.at(j) == QLatin1Char('_')))
                ++j;
            if (j < n && s.at(j) == QLatin1Char('$')) {
                const QString tag = s.mid(i, j - i + 1);
                const int close = int(s.indexOf(tag, j + 1));
                i = close < 0 ? n : close + int(tag.size());
                push(Tok::String, st, i);
            } else {
                ++i;
                push(Tok::Op, st, i);
            }
        } else if (c.isDigit() || (c == QLatin1Char('.') && c2.isDigit())) {
            while (i < n && (s.at(i).isDigit() || s.at(i) == QLatin1Char('.')))
                ++i;
            if (i < n && (s.at(i) == QLatin1Char('e') || s.at(i) == QLatin1Char('E'))) {
                ++i;
                if (i < n && (s.at(i) == QLatin1Char('+') || s.at(i) == QLatin1Char('-')))
                    ++i;
                while (i < n && s.at(i).isDigit())
                    ++i;
            }
            push(Tok::Number, st, i);
        } else if (isWord(c)) {
            while (i < n && isWord(s.at(i)))
                ++i;
            push(Tok::Word, st, i);
        } else if (c == QLatin1Char('(')) { ++i; push(Tok::Open, st, i); }
        else if (c == QLatin1Char(')')) { ++i; push(Tok::Close, st, i); }
        else if (c == QLatin1Char(',')) { ++i; push(Tok::Comma, st, i); }
        else if (c == QLatin1Char(';')) { ++i; push(Tok::Semi, st, i); }
        else if (c == QLatin1Char('.')) { ++i; push(Tok::Dot, st, i); }
        else {
            static const char* const multi[] = { "->>", "<>", "<=", ">=", "!=", "::", "||", ":=", "->", "+=", "-=", "*=", "/=" };
            int len = 1;
            for (const char* m : multi)
                if (QStringView(s).mid(i).startsWith(QLatin1String(m))) { len = int(qstrlen(m)); break; }
            i += len;
            push(Tok::Op, st, i);
        }
    }
    return out;
}

const QSet<QString>& keywords()
{
    static const QSet<QString> k = [] {
        QSet<QString> s;
        const char* const words[] = {
            "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "HAVING", "UNION", "ALL", "EXCEPT",
            "INTERSECT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "JOIN", "INNER", "LEFT",
            "RIGHT", "FULL", "OUTER", "CROSS", "APPLY", "ON", "AS", "AND", "OR", "NOT", "IN", "IS", "NULL",
            "LIKE", "ILIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "DISTINCT", "TOP",
            "PERCENT", "WITH", "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "PROCEDURE", "PROC", "FUNCTION",
            "TRIGGER", "INDEX", "DECLARE", "EXEC", "EXECUTE", "BEGIN", "COMMIT", "ROLLBACK", "TRAN",
            "TRANSACTION", "RETURN", "RETURNS", "IF", "WHILE", "PRINT", "GO", "USE", "ASC", "DESC", "LIMIT",
            "OFFSET", "FETCH", "NEXT", "ROWS", "ROW", "ONLY", "RETURNING", "MERGE", "USING", "MATCHED",
            "OUTPUT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE", "CHECK",
            "IDENTITY", "OVER", "PARTITION", "GRANT", "REVOKE", "TRUNCATE", "TRY", "CATCH", "THROW",
            "RAISERROR", "CURSOR", "OPEN", "CLOSE", "DEALLOCATE", "OF", "FOR", "RECURSIVE", "LATERAL",
            "CALL", "DO", "LANGUAGE", "REPLACE", "NOCOUNT", "OFF", "OR", "TO", "ADD", "COLUMN", "NOLOCK",
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "BIT", "DECIMAL", "NUMERIC", "FLOAT", "REAL",
            "MONEY", "VARCHAR", "NVARCHAR", "CHAR", "NCHAR", "TEXT", "NTEXT", "DATE", "DATETIME",
            "DATETIME2", "TIME", "TIMESTAMP", "UNIQUEIDENTIFIER", "VARBINARY", "BOOLEAN", "SERIAL", "MAX",
            "CONCURRENTLY", "TEMP", "TEMPORARY", "CASCADE", "RESTRICT", "NULLS", "FIRST", "LAST",
            "INSTEAD", "AFTER", "BEFORE", "EACH", "OUT", "INOUT", "WAITFOR", "DELAY", "BREAK", "CONTINUE",
            "GOTO", "SAVE", "WORK", "ISOLATION", "LEVEL", "READ", "COMMITTED", "UNCOMMITTED", "SERIALIZABLE",
            "SNAPSHOT", "REPEATABLE", "LOCAL", "GLOBAL", "STATIC", "DYNAMIC", "FORWARD_ONLY", "SCROLL",
        };
        for (const char* w : words)
            s.insert(QString::fromLatin1(w));
        return s;
    }();
    return k;
}

const QSet<QString>& functions()
{
    static const QSet<QString> f = [] {
        QSet<QString> s;
        const char* const words[] = {
            "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "ISNULL", "NULLIF", "CAST", "CONVERT",
            "TRY_CAST", "TRY_CONVERT", "GETDATE", "GETUTCDATE", "SYSDATETIME", "LEN", "LENGTH", "SUBSTRING",
            "REPLACE", "TRIM", "LTRIM", "RTRIM", "LOWER", "UPPER", "CONCAT", "CONCAT_WS", "ROUND", "ABS",
            "CEILING", "FLOOR", "DATEDIFF", "DATEADD", "DATEPART", "DATENAME", "EOMONTH", "FORMAT",
            "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NOW",
            "STRING_AGG", "STRING_SPLIT", "LEFT", "RIGHT", "CHARINDEX", "PATINDEX", "STUFF", "IIF",
            "NEWID", "SCOPE_IDENTITY", "OBJECT_ID", "DB_NAME", "SCHEMA_NAME", "TYPE_NAME", "EXTRACT",
            "DATE_TRUNC", "TO_CHAR", "TO_DATE", "ARRAY_AGG", "JSON_VALUE", "JSON_QUERY", "OPENJSON",
            "POSITION", "GREATEST", "LEAST", "CURRENT_TIMESTAMP", "CURRENT_DATE",
        };
        for (const char* w : words)
            s.insert(QString::fromLatin1(w));
        return s;
    }();
    return f;
}

} // namespace

QString SqlEditorOps::formatSql(const QString& sql, bool postgres) const
{
    const QVector<Tok> toks = tokenize(sql, postgres);
    const int n = int(toks.size());

    // A paren frame: a subquery gets its own clause layout, indented one level
    // past the line it opened on; any other paren stays inline.
    struct Frame
    {
        bool layout = true;  // clause keywords break lines here
        int indent = 0;      // clause indent
        int closeIndent = 0; // indent of the line the paren opened on
        QString clause;      // current clause keyword (SELECT, SET, WHERE, ...)
        bool listBreak = false; // break after each top-level comma
        int caseDepth = 0;
        bool between = false;
    };
    QVector<Frame> frames { Frame{} };
    QString out;
    bool atLineStart = true;
    int lineIndent = 0;
    const Tok* prev = nullptr;
    QString prevUpper;

    const auto newline = [&](int indent, bool blank = false) {
        while (out.endsWith(QLatin1Char(' ')))
            out.chop(1);
        if (!out.isEmpty()) {
            if (!out.endsWith(QLatin1Char('\n')))
                out += QLatin1Char('\n');
            if (blank && !out.endsWith(QLatin1String("\n\n")))
                out += QLatin1Char('\n');
        }
        out += QString(std::max(0, indent) * 4, QLatin1Char(' '));
        atLineStart = true;
        lineIndent = std::max(0, indent);
    };
    const auto nextSig = [&](int from) {
        for (int j = from; j < n; ++j)
            if (toks.at(j).kind != Tok::LineComment && toks.at(j).kind != Tok::BlockComment)
                return j;
        return -1;
    };
    const auto upperAt = [&](int j) { return j >= 0 && j < n ? toks.at(j).upper() : QString(); };
    const auto isJoinStart = [&](int j) {
        const QString w = upperAt(j);
        if (w == QLatin1String("JOIN"))
            return true;
        if (w == QLatin1String("INNER") || w == QLatin1String("LEFT") || w == QLatin1String("RIGHT")
            || w == QLatin1String("FULL") || w == QLatin1String("CROSS") || w == QLatin1String("OUTER")) {
            const int a = nextSig(j + 1);
            const QString w2 = upperAt(a);
            if (w2 == QLatin1String("JOIN") || w2 == QLatin1String("APPLY"))
                return true;
            if (w2 == QLatin1String("OUTER"))
                return upperAt(nextSig(a + 1)) == QLatin1String("JOIN");
        }
        return false;
    };
    // Whether a SELECT list (from token j on) has a top-level comma before its
    // FROM/INTO/WHERE/... — only then is it broken one column per line.
    const auto selectHasList = [&](int j) {
        int depth = 0;
        for (; j < n; ++j) {
            const Tok& t = toks.at(j);
            if (t.kind == Tok::Open) ++depth;
            else if (t.kind == Tok::Close) { if (--depth < 0) return false; }
            else if (t.kind == Tok::Semi && depth == 0) return false;
            else if (t.kind == Tok::Comma && depth == 0) return true;
            else if (t.kind == Tok::Word && depth == 0) {
                static const QSet<QString> stop = { QStringLiteral("FROM"), QStringLiteral("INTO"),
                    QStringLiteral("WHERE"), QStringLiteral("UNION"), QStringLiteral("GROUP"),
                    QStringLiteral("ORDER"), QStringLiteral("EXCEPT"), QStringLiteral("INTERSECT") };
                if (stop.contains(t.upper()))
                    return false;
            }
        }
        return false;
    };

    static const QSet<QString> clauseStarts = {
        QStringLiteral("SELECT"), QStringLiteral("FROM"), QStringLiteral("WHERE"), QStringLiteral("GROUP"),
        QStringLiteral("ORDER"), QStringLiteral("HAVING"), QStringLiteral("UNION"), QStringLiteral("EXCEPT"),
        QStringLiteral("INTERSECT"), QStringLiteral("INSERT"), QStringLiteral("VALUES"), QStringLiteral("UPDATE"),
        QStringLiteral("SET"), QStringLiteral("DELETE"), QStringLiteral("LIMIT"), QStringLiteral("OFFSET"),
        QStringLiteral("RETURNING"), QStringLiteral("MERGE"), QStringLiteral("USING"), QStringLiteral("WHEN"),
        QStringLiteral("OUTPUT"), QStringLiteral("DECLARE"), QStringLiteral("EXEC"), QStringLiteral("EXECUTE"),
        QStringLiteral("PRINT"), QStringLiteral("IF"), QStringLiteral("ELSE"), QStringLiteral("WHILE"),
        QStringLiteral("RETURN"), QStringLiteral("CREATE"), QStringLiteral("ALTER"), QStringLiteral("DROP"),
        QStringLiteral("TRUNCATE"), QStringLiteral("USE"), QStringLiteral("COMMIT"), QStringLiteral("ROLLBACK"),
        QStringLiteral("CALL"), QStringLiteral("GRANT"), QStringLiteral("REVOKE"), QStringLiteral("WITH"),
        QStringLiteral("THROW"), QStringLiteral("RAISERROR"), QStringLiteral("FETCH"),
    };

    for (int i = 0; i < n; ++i) {
        const Tok& t = toks.at(i);
        Frame& f = frames.last();
        const QString up = t.upper();
        bool space = true;

        if (t.kind == Tok::LineComment || t.kind == Tok::BlockComment) {
            if (t.newlinesBefore > 0 && !atLineStart)
                newline(lineIndent, t.newlinesBefore > 1);
            else if (t.newlinesBefore > 1)
                newline(lineIndent, true);
            if (!atLineStart)
                out += QLatin1Char(' ');
            out += t.text;
            atLineStart = false;
            if (t.kind == Tok::LineComment)
                newline(lineIndent);
            else if (i + 1 < n && toks.at(i + 1).newlinesBefore > 0)
                newline(lineIndent);
            continue;
        }

        if (t.kind == Tok::Word) {
            // GO on its own line stays there, flush left.
            if (up == QLatin1String("GO") && t.newlinesBefore > 0
                && (i + 1 >= n || toks.at(i + 1).newlinesBefore > 0 || toks.at(i + 1).kind == Tok::Number)) {
                newline(0);
                out += QStringLiteral("GO");
                if (i + 1 < n && toks.at(i + 1).kind == Tok::Number && toks.at(i + 1).newlinesBefore == 0)
                    out += QLatin1Char(' ') + toks.at(++i).text;
                frames = { Frame{} };
                newline(0, true);
                prev = nullptr;
                prevUpper.clear();
                continue;
            }
            const bool kw = keywords().contains(up) && !(prev && prev->kind == Tok::Dot);
            const int nx = nextSig(i + 1);
            const bool callNext = nx >= 0 && toks.at(nx).kind == Tok::Open && nx == i + 1;
            const QString word = (kw || (functions().contains(up) && callNext)) ? up : t.text;

            if (f.layout && f.caseDepth == 0 && kw) {
                const bool afterDelete = prevUpper == QLatin1String("DELETE") && up == QLatin1String("FROM");
                const bool afterInsert = prevUpper == QLatin1String("INSERT") && up == QLatin1String("INTO");
                const bool afterUnion = (prevUpper == QLatin1String("UNION") || prevUpper == QLatin1String("ALL")
                                         || prevUpper == QLatin1String("EXCEPT") || prevUpper == QLatin1String("INTERSECT"))
                                        && up != QLatin1String("SELECT");
                const bool setInUpdate = up == QLatin1String("SET");
                const bool isClause = (clauseStarts.contains(up) && !afterDelete && !afterInsert && !afterUnion
                                       && !(up == QLatin1String("WITH") && prev && prev->kind != Tok::Semi
                                            && !clauseStarts.contains(prevUpper))
                                       && !(up == QLatin1String("FETCH") && f.clause != QLatin1String("OFFSET")
                                            && f.clause != QLatin1String("ORDER"))
                                       && !(up == QLatin1String("WHEN") && f.clause != QLatin1String("MERGE")
                                            && f.clause != QLatin1String("USING") && f.clause != QLatin1String("WHEN"))
                                       && !(up == QLatin1String("ELSE") && f.caseDepth > 0)
                                       && !(up == QLatin1String("FOR") || prevUpper == QLatin1String("FOR")))
                                      || setInUpdate;
                if (isJoinStart(i) && !(prevUpper == QLatin1String("INNER") || prevUpper == QLatin1String("LEFT")
                                        || prevUpper == QLatin1String("RIGHT") || prevUpper == QLatin1String("FULL")
                                        || prevUpper == QLatin1String("CROSS") || prevUpper == QLatin1String("OUTER"))) {
                    newline(f.indent);
                    f.clause = QStringLiteral("JOIN");
                    f.listBreak = false;
                } else if (up == QLatin1String("ON") && (f.clause == QLatin1String("JOIN"))) {
                    newline(f.indent + 1);
                    f.clause = QStringLiteral("ON");
                } else if ((up == QLatin1String("AND") || up == QLatin1String("OR"))
                           && (f.clause == QLatin1String("WHERE") || f.clause == QLatin1String("HAVING")
                               || f.clause == QLatin1String("ON"))) {
                    if (f.between && up == QLatin1String("AND"))
                        f.between = false;
                    else
                        newline(f.indent + 1);
                } else if (up == QLatin1String("BEGIN")) {
                    const QString w2 = upperAt(nx);
                    const bool tran = w2 == QLatin1String("TRAN") || w2 == QLatin1String("TRANSACTION")
                                      || w2 == QLatin1String("DISTRIBUTED") || postgres;
                    newline(f.indent);
                    out += word;
                    atLineStart = false;
                    prev = &t;
                    prevUpper = up;
                    if (!tran) {
                        if (w2 == QLatin1String("TRY") || w2 == QLatin1String("CATCH")) {
                            out += QLatin1Char(' ') + toks.at(nx).upper();
                            i = nx;
                        }
                        f.indent += 1;
                        f.clause.clear();
                        newline(f.indent);
                    }
                    continue;
                } else if (up == QLatin1String("END")) {
                    f.indent = std::max(0, f.indent - 1);
                    newline(f.indent);
                    f.clause.clear();
                } else if (isClause) {
                    const bool blank = t.newlinesBefore > 1 && frames.size() == 1;
                    if (!out.isEmpty())
                        newline(f.indent, blank);
                    f.clause = up;
                    f.listBreak = false;
                    f.between = false;
                    if (up == QLatin1String("SET") || up == QLatin1String("UPDATE"))
                        f.listBreak = up == QLatin1String("SET");
                    if (up == QLatin1String("SELECT")) {
                        out += word;
                        atLineStart = false;
                        prev = &t;
                        prevUpper = up;
                        // Keep DISTINCT / TOP n [PERCENT] on the SELECT line.
                        int j = nextSig(i + 1);
                        while (j >= 0) {
                            const QString w = upperAt(j);
                            if (w == QLatin1String("DISTINCT") || w == QLatin1String("ALL")) {
                                out += QLatin1Char(' ') + w;
                                i = j;
                            } else if (w == QLatin1String("TOP")) {
                                out += QStringLiteral(" TOP");
                                i = j;
                                const int a = nextSig(j + 1);
                                if (a >= 0 && toks.at(a).kind == Tok::Number) {
                                    out += QLatin1Char(' ') + toks.at(a).text;
                                    i = a;
                                } else if (a >= 0 && toks.at(a).kind == Tok::Open) {
                                    int depth = 0, b = a;
                                    QString inner;
                                    for (; b < n; ++b) {
                                        if (toks.at(b).kind == Tok::Open) ++depth;
                                        if (toks.at(b).kind == Tok::Close && --depth == 0) break;
                                    }
                                    for (int k = a; k <= b && k < n; ++k)
                                        inner += toks.at(k).text;
                                    out += QLatin1Char(' ') + inner;
                                    i = std::min(b, n - 1);
                                }
                                const int p = nextSig(i + 1);
                                if (upperAt(p) == QLatin1String("PERCENT")) {
                                    out += QStringLiteral(" PERCENT");
                                    i = p;
                                }
                            } else {
                                break;
                            }
                            j = nextSig(i + 1);
                        }
                        f.listBreak = selectHasList(i + 1);
                        if (f.listBreak)
                            newline(f.indent + 1);
                        prev = &toks.at(i);
                        continue;
                    }
                }
            }
            if (up == QLatin1String("CASE"))
                ++f.caseDepth;
            else if (up == QLatin1String("END") && f.caseDepth > 0)
                --f.caseDepth;
            else if (up == QLatin1String("BETWEEN"))
                f.between = true;

            if (prev && (prev->kind == Tok::Open || prev->kind == Tok::Dot))
                space = false;
            if (prev && prev->kind == Tok::Op && (prev->text == QLatin1String("::")))
                space = false;
            if (prev && prev->kind == Tok::Op && prev->text == QLatin1String("@"))
                space = false;
            if (!atLineStart && space)
                out += QLatin1Char(' ');
            out += word;
            atLineStart = false;
            prev = &t;
            prevUpper = up;
            continue;
        }

        switch (t.kind) {
        case Tok::Open: {
            const int nx = nextSig(i + 1);
            const QString w = upperAt(nx);
            const bool sub = w == QLatin1String("SELECT") || w == QLatin1String("WITH");
            // Function call / identifier(...) hugs its name; keywords keep a space.
            if (prev && (prev->kind == Tok::Word || prev->kind == Tok::Quoted)) {
                const bool prevKw = keywords().contains(prevUpper) && !functions().contains(prevUpper);
                space = prevKw && prevUpper != QLatin1String("MAX");
            }
            if (prev && (prev->kind == Tok::Open || prev->kind == Tok::Op || prev->kind == Tok::Dot))
                space = prev->kind == Tok::Op && prev->text != QLatin1String("::");
            if (!atLineStart && space && prev)
                out += QLatin1Char(' ');
            out += QLatin1Char('(');
            atLineStart = false;
            Frame nf;
            nf.closeIndent = lineIndent;
            if (sub) {
                nf.layout = true;
                nf.indent = lineIndent + 1;
                frames.append(nf);
                newline(nf.indent);
            } else {
                nf.layout = false;
                nf.indent = lineIndent;
                frames.append(nf);
            }
            break;
        }
        case Tok::Close: {
            Frame closed = frames.size() > 1 ? frames.takeLast() : frames.last();
            if (closed.layout && frames.size() >= 1 && closed.indent > closed.closeIndent)
                newline(closed.closeIndent);
            out += QLatin1Char(')');
            atLineStart = false;
            break;
        }
        case Tok::Comma:
            out += QLatin1Char(',');
            atLineStart = false;
            if (f.layout && f.listBreak && f.caseDepth == 0)
                newline(f.indent + 1);
            break;
        case Tok::Semi:
            out += QLatin1Char(';');
            atLineStart = false;
            if (frames.size() == 1) {
                f.clause.clear();
                f.listBreak = false;
                const int nx = i + 1 < n ? i + 1 : -1;
                const bool trailingComment = nx >= 0 && toks.at(nx).kind == Tok::LineComment
                                             && toks.at(nx).newlinesBefore == 0;
                if (!trailingComment && nx >= 0)
                    newline(f.indent, f.indent == 0);
            }
            break;
        case Tok::Dot:
            out += QLatin1Char('.');
            atLineStart = false;
            break;
        case Tok::Op: {
            const bool tight = t.text == QLatin1String("::") || t.text == QLatin1String("@");
            const bool unary = (t.text == QLatin1String("-") || t.text == QLatin1String("+"))
                               && (!prev || prev->kind == Tok::Op || prev->kind == Tok::Open
                                   || prev->kind == Tok::Comma
                                   || (prev->kind == Tok::Word && keywords().contains(prevUpper)));
            const bool star = t.text == QLatin1String("*") && prev
                              && (prev->kind == Tok::Dot || prev->kind == Tok::Open);
            if (!atLineStart && !tight && !star && prev && prev->kind != Tok::Open
                && !(prev->kind == Tok::Op && prev->text == QLatin1String("::")))
                out += QLatin1Char(' ');
            out += t.text;
            atLineStart = false;
            prev = &t;
            prevUpper.clear();
            if (unary || tight)
                continue; // next token hugs
            // A following token adds its own space.
            continue;
        }
        default: { // Number, String, Quoted
            if (prev && (prev->kind == Tok::Open || prev->kind == Tok::Dot))
                space = false;
            if (prev && prev->kind == Tok::Op) {
                const bool unaryPrev = (prev->text == QLatin1String("-") || prev->text == QLatin1String("+"))
                                       && (i < 2 || toks.at(i - 2).kind == Tok::Op || toks.at(i - 2).kind == Tok::Open
                                           || toks.at(i - 2).kind == Tok::Comma
                                           || (toks.at(i - 2).kind == Tok::Word
                                               && keywords().contains(toks.at(i - 2).upper())));
                if (unaryPrev || prev->text == QLatin1String("::") || prev->text == QLatin1String("@"))
                    space = false;
            }
            if (!atLineStart && space && prev)
                out += QLatin1Char(' ');
            out += t.text;
            atLineStart = false;
            break;
        }
        }
        prev = &t;
        prevUpper = t.kind == Tok::Word ? up : QString();
    }
    while (out.endsWith(QLatin1Char(' ')) || out.endsWith(QLatin1Char('\n')))
        out.chop(1);
    return out;
}
