#pragma once

#include "SqlBackend.h"

#include <sybdb.h>

// SQL Server connector over FreeTDS db-lib. db-lib is single-threaded per
// connection, which the owning SqlSession worker thread guarantees.
class TdsBackend : public SqlBackend
{
public:
    ~TdsBackend() override;

    QString open(const QString& host, int port, const QString& user,
                 const QString& password, const QString& database,
                 SqlConnectInfo& info) override;
    void close() override;
    bool isOpen() const override { return m_proc != nullptr; }
    bool runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err) override;
    void switchDatabase(const QString& name, QString& currentDb, QVariantList& objects) override;
    void refreshObjects(QVariantList& objects) override { if (m_proc) objects = objectList(); }
    void columnMap(QVariantMap& columns) override { if (m_proc) columns = columnList(); }
    void stats(const QString& table, qint64& rowCount, qint64& sizeKb) override;

    // Appended to by the global db-lib error/message handlers for the current
    // call; public so those C callbacks can reach it.
    QString m_err;

private:
    QStringList databaseList();
    QString currentDb();
    QVariantList objectList();
    QVariantMap columnList();
    bool runQuery(const QString& sql, QStringList& columns, QVector<QStringList>& rows,
                  int& affected, QString& err);
    QString cell(int c);

    DBPROCESS* m_proc = nullptr;
};
