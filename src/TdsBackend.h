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
    bool isDead() const override { return m_proc && DBDEAD(m_proc); }
    bool runBatch(const QString& sql, QVector<SqlResultSet>& sets,
                  QVector<SqlMessage>& messages, QString& err) override;
    void switchDatabase(const QString& name, QString& currentDb, QVariantList& objects) override;
    void refreshObjects(QVariantList& objects) override { if (m_proc) objects = objectList(); }
    void schema(QVariantMap& schema) override;
    QStringList primaryKey(const QString& table, QStringList* types = nullptr) override;
    bool inTransaction() override;
    void stats(const QString& table, qint64& rowCount, qint64& sizeKb) override;
    void setQueryTimeout(int seconds) override;

    // Appended to by the global db-lib error/message handlers for the current
    // call; public so those C callbacks can reach it.
    QString m_err;
    // While runBatch() runs, where the handlers record server messages (PRINT,
    // RAISERROR, errors with their line numbers); null otherwise, so metadata
    // queries stay silent.
    QVector<SqlMessage>* m_msgs = nullptr;

private:
    QStringList databaseList();
    QString currentDb();
    QVariantList objectList();
    bool runQuery(const QString& sql, QStringList& columns, QVector<QStringList>& rows,
                  int& affected, QString& err);
    QString cell(int c);

    DBPROCESS* m_proc = nullptr;
};
