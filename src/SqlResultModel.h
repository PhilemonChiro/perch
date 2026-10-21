#pragma once

#include <QAbstractTableModel>
#include <QFile>
#include <QQmlEngine>
#include <QStringList>
#include <QTextStream>
#include <QUrl>
#include <QVariantList>
#include <QVector>

#include <algorithm>

// A single SQL result set, exposed to QML's TableView. Columns come from the
// query; every cell is held as a string (db-lib hands us text-bound columns in
// the worker), with NULLs represented as a null QString and rendered as "NULL".
class SqlResultModel : public QAbstractTableModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Owned by a SqlSession")
    Q_PROPERTY(QStringList columns READ columns NOTIFY resetted)
    Q_PROPERTY(int rows READ rowCountProp NOTIFY resetted)
    // Suggested pixel widths per column, sized to header + sampled cell lengths.
    Q_PROPERTY(QVariantList columnWidths READ columnWidths NOTIFY resetted)
    Q_PROPERTY(int sortColumn READ sortColumn NOTIFY sortChanged)
    Q_PROPERTY(bool sortAscending READ sortAscending NOTIFY sortChanged)
    // In-memory row filter (used when the grid isn't a server-side single table).
    Q_PROPERTY(bool filtered READ isFiltered NOTIFY filterChanged)
    Q_PROPERTY(int totalRows READ totalRows NOTIFY resetted)

public:
    explicit SqlResultModel(QObject* parent = nullptr) : QAbstractTableModel(parent) {}

    int rowCount(const QModelIndex& parent = {}) const override
    {
        return parent.isValid() ? 0 : int(m_rows.size());
    }
    int columnCount(const QModelIndex& parent = {}) const override
    {
        return parent.isValid() ? 0 : m_columns.size();
    }

    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override
    {
        if (!index.isValid() || index.row() >= m_rows.size())
            return {};
        const QStringList& row = m_rows.at(index.row());
        if (index.column() >= row.size())
            return {};
        switch (role) {
        case Qt::DisplayRole: return row.at(index.column());
        case IsNullRole: return row.at(index.column()).isNull();
        default: return {};
        }
    }

    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override
    {
        if (role == Qt::DisplayRole && orientation == Qt::Horizontal
            && section >= 0 && section < m_columns.size())
            return m_columns.at(section);
        return {};
    }

    QHash<int, QByteArray> roleNames() const override
    {
        return {{Qt::DisplayRole, "display"}, {IsNullRole, "isNull"}};
    }

    QStringList columns() const { return m_columns; }
    int rowCountProp() const { return int(m_rows.size()); }
    QVariantList columnWidths() const { return m_columnWidths; }
    int sortColumn() const { return m_sortColumn; }
    bool sortAscending() const { return m_sortAscending; }
    bool isFiltered() const { return m_filtered; }
    int totalRows() const { return int(m_allRows.size()); }

    // Filters the shown rows in memory: keeps rows whose column `column` contains
    // `text` (or equals it when `exact`). An empty column searches every column.
    // Empty text clears the filter. Operates on the full fetched set.
    Q_INVOKABLE void filter(int column, const QString& text, bool exact)
    {
        const QString needle = text;
        beginResetModel();
        if (needle.isEmpty()) {
            m_rows = m_allRows;
            m_filtered = false;
        } else {
            const QString n = needle.toLower();
            m_rows.clear();
            for (const QStringList& row : std::as_const(m_allRows)) {
                bool hit = false;
                const int from = (column >= 0 && column < m_columns.size()) ? column : 0;
                const int to = (column >= 0 && column < m_columns.size()) ? column + 1 : int(row.size());
                for (int c = from; c < to && c < row.size(); ++c) {
                    const QString v = row.at(c);
                    if (v.isNull())
                        continue;
                    if (exact ? (v.compare(needle, Qt::CaseInsensitive) == 0)
                              : v.toLower().contains(n)) {
                        hit = true;
                        break;
                    }
                }
                if (hit)
                    m_rows << row;
            }
            m_filtered = true;
        }
        m_sortColumn = -1;
        m_sortAscending = true;
        endResetModel();
        emit resetted();
        emit sortChanged();
        emit filterChanged();
    }
    Q_INVOKABLE void clearFilter() { filter(-1, QString(), false); }

    // Returns one row as a tab-joined string (for copy).
    Q_INVOKABLE QString rowText(int r) const
    {
        if (r < 0 || r >= m_rows.size())
            return {};
        return m_rows.at(r).join(QLatin1Char('\t'));
    }
    // Returns a single cell's text (NULL shown literally).
    Q_INVOKABLE QString cellText(int r, int c) const
    {
        if (r < 0 || r >= m_rows.size() || c < 0 || c >= m_rows.at(r).size())
            return {};
        const QString v = m_rows.at(r).at(c);
        return v.isNull() ? QStringLiteral("NULL") : v;
    }

    // Writes the given view-row indices (or every row when `rows` is empty) to a
    // CSV file at `path` (a plain path or a file:// URL). Returns false on any
    // file error. A field is quoted when it holds a comma, quote or newline; a
    // true SQL NULL is written as an empty field.
    Q_INVOKABLE bool exportRowsCsv(const QString& path, const QVariantList& rows) const
    {
        QString p = path.startsWith(QStringLiteral("file:")) ? QUrl(path).toLocalFile() : path;
        QFile f(p);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
            return false;
        QTextStream out(&f);
        out.setEncoding(QStringConverter::Utf8);
        const auto field = [](const QString& v) -> QString {
            if (v.isNull())
                return {};
            QString s = v;
            if (s.contains(QLatin1Char(',')) || s.contains(QLatin1Char('"'))
                || s.contains(QLatin1Char('\n')) || s.contains(QLatin1Char('\r'))) {
                s.replace(QLatin1Char('"'), QStringLiteral("\"\""));
                return QLatin1Char('"') + s + QLatin1Char('"');
            }
            return s;
        };
        QStringList hdr;
        for (const QString& c : m_columns)
            hdr << field(c);
        out << hdr.join(QLatin1Char(',')) << "\r\n";
        const auto writeRow = [&](int r) {
            if (r < 0 || r >= m_rows.size())
                return;
            QStringList line;
            const QStringList& row = m_rows.at(r);
            for (const QString& v : row)
                line << field(v);
            out << line.join(QLatin1Char(',')) << "\r\n";
        };
        if (rows.isEmpty())
            for (int r = 0; r < m_rows.size(); ++r)
                writeRow(r);
        else
            for (const QVariant& rv : rows)
                writeRow(rv.toInt());
        f.close();
        return f.error() == QFileDevice::NoError;
    }

    // Sorts by a column; clicking the same column again flips direction.
    Q_INVOKABLE void sortByColumn(int column)
    {
        if (column < 0 || column >= m_columns.size())
            return;
        if (m_sortColumn == column)
            m_sortAscending = !m_sortAscending;
        else {
            m_sortColumn = column;
            m_sortAscending = true;
        }
        const bool asc = m_sortAscending;
        beginResetModel();
        std::stable_sort(m_rows.begin(), m_rows.end(), [column, asc](const QStringList& a, const QStringList& b) {
            const QString& x = column < a.size() ? a.at(column) : QString();
            const QString& y = column < b.size() ? b.at(column) : QString();
            // NULLs sort last regardless of direction.
            if (x.isNull() != y.isNull())
                return y.isNull();
            bool xok = false, yok = false;
            const double xn = x.toDouble(&xok);
            const double yn = y.toDouble(&yok);
            int cmp;
            if (xok && yok)
                cmp = xn < yn ? -1 : (xn > yn ? 1 : 0);
            else
                cmp = QString::compare(x, y, Qt::CaseInsensitive);
            return asc ? cmp < 0 : cmp > 0;
        });
        endResetModel();
        emit sortChanged();
    }

    // A detached deep copy parented to `parent` (or JS-owned when null). Used to
    // keep a query tab's results alive after a later query reuses the session's
    // live models. Copies the full fetched set, unfiltered and unsorted.
    SqlResultModel* clone(QObject* parent) const
    {
        auto* m = new SqlResultModel(parent);
        m->m_columns = m_columns;
        m->m_rows = m_allRows;
        m->m_allRows = m_allRows;
        m->m_columnWidths = m_columnWidths;
        return m;
    }

    void reset(const QStringList& columns, QVector<QStringList> rows)
    {
        beginResetModel();
        m_columns = columns;
        m_rows = std::move(rows);
        m_allRows = m_rows;
        m_filtered = false;
        m_sortColumn = -1;
        m_sortAscending = true;
        computeWidths();
        endResetModel();
        emit resetted();
        emit sortChanged();
        emit filterChanged();
    }

signals:
    void resetted();
    void sortChanged();
    void filterChanged();

private:
    enum Roles { IsNullRole = Qt::UserRole + 1 };

    // Pixel width per column from the header and a sample of cell lengths.
    void computeWidths()
    {
        m_columnWidths.clear();
        const int sample = std::min(int(m_rows.size()), 200);
        for (int c = 0; c < m_columns.size(); ++c) {
            int maxLen = m_columns.at(c).size();
            for (int r = 0; r < sample; ++r)
                if (c < m_rows.at(r).size()) {
                    const QString& v = m_rows.at(r).at(c);
                    maxLen = std::max(maxLen, v.isNull() ? 4 : int(v.size()));
                }
            // ~7px per mono char + padding, clamped to a readable range.
            int px = maxLen * 7 + 28;
            px = std::clamp(px, 80, 440);
            m_columnWidths.append(px);
        }
    }

    QStringList m_columns;
    QVector<QStringList> m_rows;    // the rows currently shown (filtered/sorted)
    QVector<QStringList> m_allRows; // the full fetched set, for in-memory filtering
    QVariantList m_columnWidths;
    int m_sortColumn = -1;
    bool m_sortAscending = true;
    bool m_filtered = false;
};
