#pragma once

#include <QAbstractTableModel>
#include <QQmlEngine>
#include <QStringList>
#include <QVector>

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
        case Qt::DisplayRole:
            return row.at(index.column());
        case IsNullRole:
            return row.at(index.column()).isNull();
        default:
            return {};
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

    void reset(const QStringList& columns, QVector<QStringList> rows)
    {
        beginResetModel();
        m_columns = columns;
        m_rows = std::move(rows);
        endResetModel();
        emit resetted();
    }

signals:
    void resetted();

private:
    enum Roles { IsNullRole = Qt::UserRole + 1 };
    QStringList m_columns;
    QVector<QStringList> m_rows;
};
