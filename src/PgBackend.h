#pragma once

#include "SqlBackend.h"

#include <QMutex>

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
    bool isDead() const override { return m_conn && PQstatus(m_conn) == CONNECTION_BAD; }
    bool runBatch(const QString& sql, QVector<SqlResultSet>& sets,
                  QVector<SqlMessage>& messages, QString& err) override;
    void switchDatabase(const QString& name, QString& currentDb, QVariantList& objects) override;
    void refreshObjects(QVariantList& objects) override { if (m_conn) objects = objectList(); }
    void schema(QVariantMap& schema) override;
    QStringList primaryKey(const QString& table, QStringList* types = nullptr) override;
    bool inTransaction() override;
    void stats(const QString& table, qint64& rowCount, qint64& sizeKb) override;

    // While runBatch() runs, where the notice receiver records NOTICE/WARNING
    // messages; null otherwise. Public for the C callback.
    QVector<SqlMessage>* m_msgs = nullptr;

protected:
    // PQcancel() on the GUI thread; libpq documents it as thread-safe.
    void interrupt() override;

private:
    // Opens a fresh connection to `database`, filling server metadata. Reused by
    // both open() and switchDatabase(). Returns "" on success, else an error.
    QString doOpen(const QString& database, SqlConnectInfo& info);
    QStringList databaseList();
    QString currentDb();
    QVariantList objectList();
    // Runs a single metadata query, returning its first column as a list.
    QStringList firstColumn(const QString& sql);
    // Runs a metadata query, returning every row as text (NULL as ""). False on
    // any error.
    bool rows(const QString& sql, QVector<QStringList>& out);

    PGconn* m_conn = nullptr;
    // Cancel handle for m_conn. Replaced on every (re)connect, so guarded for
    // interrupt() reading it from the GUI thread.
    QMutex m_cancelLock;
    PGcancel* m_cancel = nullptr;
    // Login kept so switchDatabase() can reopen against another database.
    QString m_host, m_user, m_password;
    int m_port = 5432;
};
