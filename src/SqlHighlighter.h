#pragma once

#include <QColor>
#include <QQmlEngine>
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QSyntaxHighlighter>
#include <QTextCharFormat>
#include <QTextDocument>
#include <QVector>

// Colourises a T-SQL document: keywords, built-in functions, string and numeric
// literals, [bracketed] identifiers, operators and both comment styles. Rules
// are applied in order so later ones (strings, comments) win over keywords they
// contain.
class SqlTextHighlighter : public QSyntaxHighlighter
{
public:
    using QSyntaxHighlighter::QSyntaxHighlighter;

    struct Rule
    {
        QRegularExpression re;
        QTextCharFormat fmt;
    };

    QVector<Rule> rules;
    QTextCharFormat commentFmt;

protected:
    void highlightBlock(const QString& text) override
    {
        for (const Rule& r : rules) {
            auto it = r.re.globalMatch(text);
            while (it.hasNext()) {
                const auto m = it.next();
                setFormat(int(m.capturedStart()), int(m.capturedLength()), r.fmt);
            }
        }

        // Multi-line /* ... */ comments, carried across lines via block state.
        static const QRegularExpression startRe(QStringLiteral("/\\*"));
        static const QRegularExpression endRe(QStringLiteral("\\*/"));
        setCurrentBlockState(0);
        int start = (previousBlockState() == 1) ? 0 : int(text.indexOf(startRe));
        while (start >= 0) {
            const auto m = endRe.match(text, start);
            int len;
            if (!m.hasMatch()) {
                setCurrentBlockState(1);
                len = text.length() - start;
            } else {
                len = int(m.capturedEnd()) - start;
            }
            setFormat(start, len, commentFmt);
            start = int(text.indexOf(startRe, start + len));
        }
    }
};

// QML-attachable installer: set `document` to a TextArea's textDocument and the
// colour properties (bound to the theme) to paint SQL. Rebuilds and re-highlights
// whenever the document or any colour changes, so it follows light/dark switches.
class SqlHighlighter : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickTextDocument* document READ document WRITE setDocument NOTIFY documentChanged)
    Q_PROPERTY(QColor keywordColor MEMBER m_keyword WRITE setKeyword NOTIFY changed)
    Q_PROPERTY(QColor functionColor MEMBER m_function WRITE setFunction NOTIFY changed)
    Q_PROPERTY(QColor stringColor MEMBER m_string WRITE setString NOTIFY changed)
    Q_PROPERTY(QColor numberColor MEMBER m_number WRITE setNumber NOTIFY changed)
    Q_PROPERTY(QColor commentColor MEMBER m_comment WRITE setComment NOTIFY changed)
    Q_PROPERTY(QColor identifierColor MEMBER m_identifier WRITE setIdentifier NOTIFY changed)
    Q_PROPERTY(QColor operatorColor MEMBER m_operator WRITE setOperator NOTIFY changed)

public:
    explicit SqlHighlighter(QObject* parent = nullptr) : QObject(parent) {}

    QQuickTextDocument* document() const { return m_document; }
    void setDocument(QQuickTextDocument* doc)
    {
        if (m_document == doc)
            return;
        m_document = doc;
        delete m_hl;
        m_hl = nullptr;
        if (m_document && m_document->textDocument())
            m_hl = new SqlTextHighlighter(m_document->textDocument());
        rebuild();
        emit documentChanged();
    }

    void setKeyword(const QColor& c) { m_keyword = c; rebuild(); emit changed(); }
    void setFunction(const QColor& c) { m_function = c; rebuild(); emit changed(); }
    void setString(const QColor& c) { m_string = c; rebuild(); emit changed(); }
    void setNumber(const QColor& c) { m_number = c; rebuild(); emit changed(); }
    void setComment(const QColor& c) { m_comment = c; rebuild(); emit changed(); }
    void setIdentifier(const QColor& c) { m_identifier = c; rebuild(); emit changed(); }
    void setOperator(const QColor& c) { m_operator = c; rebuild(); emit changed(); }

signals:
    void documentChanged();
    void changed();

private:
    static QRegularExpression ci(const QString& pat)
    {
        return QRegularExpression(pat, QRegularExpression::CaseInsensitiveOption);
    }

    void rebuild()
    {
        if (!m_hl)
            return;
        m_hl->rules.clear();

        QTextCharFormat kw;
        kw.setForeground(m_keyword);
        kw.setFontWeight(QFont::DemiBold);
        static const QString keywords = QStringLiteral(
            "add|all|alter|and|any|as|asc|authorization|backup|begin|between|break|browse|bulk|by|"
            "cascade|case|check|checkpoint|close|clustered|coalesce|collate|column|commit|constraint|"
            "continue|create|cross|current|cursor|database|dbcc|deallocate|declare|default|delete|deny|"
            "desc|disk|distinct|distributed|double|drop|else|end|errlvl|escape|except|exec|execute|"
            "exists|exit|external|fetch|file|fillfactor|for|foreign|freetext|from|full|function|goto|"
            "grant|group|having|identity|if|in|index|inner|insert|intersect|into|is|join|key|kill|left|"
            "like|lineno|merge|national|nocheck|nonclustered|not|null|nullif|of|off|offsets|on|open|"
            "option|or|order|outer|over|percent|pivot|plan|primary|print|proc|procedure|public|"
            "raiserror|read|readtext|reconfigure|references|replication|restore|restrict|return|revert|"
            "revoke|right|rollback|rowcount|rowguidcol|rule|save|schema|securityaudit|select|session_user|"
            "set|setuser|shutdown|some|statistics|system_user|table|tablesample|textsize|then|to|top|tran|"
            "transaction|trigger|truncate|try|union|unique|unpivot|update|updatetext|use|user|values|"
            "varying|view|waitfor|when|where|while|with|writetext|int|bigint|smallint|tinyint|bit|decimal|"
            "numeric|money|float|real|datetime|date|time|char|varchar|nchar|nvarchar|text|ntext|binary|"
            "varbinary|uniqueidentifier|xml|asc");
        m_hl->rules.push_back({ci(QStringLiteral("\\b(?:%1)\\b").arg(keywords)), kw});

        QTextCharFormat fn;
        fn.setForeground(m_function);
        static const QString funcs = QStringLiteral(
            "count|sum|avg|min|max|cast|convert|isnull|getdate|getutcdate|datepart|dateadd|datediff|"
            "datename|day|month|year|len|substring|charindex|patindex|replace|stuff|left|right|ltrim|"
            "rtrim|trim|upper|lower|str|concat|concat_ws|format|row_number|rank|dense_rank|ntile|"
            "object_id|db_name|db_id|schema_name|suser_sname|abs|ceiling|floor|round|power|sqrt|"
            "newid|coalesce|iif|try_cast|try_convert|string_agg|json_value|json_query|object_name");
        m_hl->rules.push_back({ci(QStringLiteral("\\b(?:%1)(?=\\s*\\()").arg(funcs)), fn});

        QTextCharFormat num;
        num.setForeground(m_number);
        m_hl->rules.push_back({QRegularExpression(QStringLiteral("\\b\\d+(?:\\.\\d+)?\\b")), num});

        QTextCharFormat ident;
        ident.setForeground(m_identifier);
        m_hl->rules.push_back({QRegularExpression(QStringLiteral("\\[[^\\]]*\\]")), ident});

        QTextCharFormat op;
        op.setForeground(m_operator);
        m_hl->rules.push_back({QRegularExpression(QStringLiteral("[=<>!+*/%,;().]|(?<!-)-(?!-)")), op});

        QTextCharFormat str;
        str.setForeground(m_string);
        m_hl->rules.push_back({ci(QStringLiteral("[Nn]?'(?:[^']|'')*'")), str});

        QTextCharFormat line;
        line.setForeground(m_comment);
        line.setFontItalic(true);
        m_hl->rules.push_back({QRegularExpression(QStringLiteral("--[^\n]*")), line});

        m_hl->commentFmt = line;
        m_hl->rehighlight();
    }

    QQuickTextDocument* m_document = nullptr;
    SqlTextHighlighter* m_hl = nullptr;
    QColor m_keyword{"#6E93FF"};
    QColor m_function{"#7FE3C6"};
    QColor m_string{"#E7A977"};
    QColor m_number{"#C99BFF"};
    QColor m_comment{"#5C606A"};
    QColor m_identifier{"#9FB4D8"};
    QColor m_operator{"#969AA3"};
};
