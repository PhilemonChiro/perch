#pragma once

#include "SqlBackend.h"

#include <libpq-fe.h>

// PostgreSQL connector over libpq. PostgreSQL cannot change database on a live
// connection, so switchDatabase() reopens using the login details kept from the
// first connect.
class PgBackend : public SqlBackend
{
public:
    ~PgBackend() override;

    QString open(const QString& host, int port, const QString& user,
                 const QString& password, const QString& database,
                 SqlConnectInfo& info) override;
    void close() override;
    bool isOpen() const override { return m_conn != nullptr; }
    bool runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err) override;
    void switchDatabase(const QString& name, QString& currentDb, QStringList& tables) override;
    void stats(const QString& table, qint64& rowCount, qint64& sizeKb) override;

private:
    // Opens a fresh connection to `database`, filling server metadata. Reused by
    // both open() and switchDatabase(). Returns "" on success, else an error.
    QString doOpen(const QString& database, SqlConnectInfo& info);
    QStringList databaseList();
    QString currentDb();
    QStringList tableList();
    // Runs a single metadata query, returning its first column as a list.
    QStringList firstColumn(const QString& sql);

    PGconn* m_conn = nullptr;
    // Login kept so switchDatabase() can reopen against another database.
    QString m_host, m_user, m_password;
    int m_port = 5432;
};
