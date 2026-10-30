#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QQuickTextDocument>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

// Text operations for the SQL editor that QML's TextArea can't do as a single
// undo step. Setting TextArea.text wipes the document's undo stack, so every
// programmatic change here goes through a QTextCursor edit block on the
// editor's QTextDocument instead — the change lands on the same stack as
// typing and Cmd+Z reverts it in one step. Line operations take the current
// selection and return the selection to restore as {start, end}.
class SqlEditorOps : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit SqlEditorOps(QObject* parent = nullptr) : QObject(parent) {}

    // Replaces [start, end) with `text`; returns the position after it.
    Q_INVOKABLE int replaceRange(QQuickTextDocument* doc, int start, int end, const QString& text);
    // Replaces the whole document.
    Q_INVOKABLE void replaceAll(QQuickTextDocument* doc, const QString& text);

    // Comments out the selected lines with "-- ", or uncomments them when all
    // non-blank ones already are.
    Q_INVOKABLE QVariantMap toggleComment(QQuickTextDocument* doc, int selStart, int selEnd);
    // Duplicates the selected lines below themselves; selects the copy.
    Q_INVOKABLE QVariantMap duplicateLines(QQuickTextDocument* doc, int selStart, int selEnd);
    // Moves the selected lines one line up (dir < 0) or down (dir > 0).
    Q_INVOKABLE QVariantMap moveLines(QQuickTextDocument* doc, int selStart, int selEnd, int dir);
    // Indents (or outdents) the selected lines by four spaces.
    Q_INVOKABLE QVariantMap indentLines(QQuickTextDocument* doc, int selStart, int selEnd, bool outdent);

    // Every match of `needle` in `text` as [{start, end}].
    Q_INVOKABLE QVariantList findAll(const QString& text, const QString& needle, bool caseSensitive,
                                     bool wholeWord, bool regex) const;
    // Replaces every match in one undo step; returns the number replaced. With
    // `regex`, \1.. in the replacement refer to capture groups.
    Q_INVOKABLE int replaceAllMatches(QQuickTextDocument* doc, const QString& needle,
                                      const QString& replacement, bool caseSensitive,
                                      bool wholeWord, bool regex);
    // The replacement text for one match at [start, end) (expands \1.. for a regex).
    Q_INVOKABLE QString expandReplacement(const QString& text, int start, int end, const QString& needle,
                                          const QString& replacement, bool caseSensitive, bool regex) const;

    // Index of the bracket matching the one at `pos` ((, ), [, ]), skipping
    // strings and comments; -1 when unmatched or not a bracket.
    Q_INVOKABLE int matchBracket(const QString& text, int pos) const;
    // Lexical state just before `pos`: 0 code, 1 inside a string or quoted
    // identifier, 2 inside a comment. Used to keep completion out of literals.
    Q_INVOKABLE int lexStateAt(const QString& text, int pos) const;

    // Reformats SQL: upper-case keywords, one clause per line, indented
    // select/set lists, joins and AND/OR conditions. Strings, quoted
    // identifiers and comments are preserved verbatim.
    Q_INVOKABLE QString formatSql(const QString& sql, bool postgres) const;
};
