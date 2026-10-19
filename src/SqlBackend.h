#pragma once

#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>

// One result set produced by a batch: its columns, its rows, and for a
// statement without a row set the affected-row count. A batch of several
// statements (e.g. two SELECTs) produces several of these.
struct SqlResultSet
{
    QStringList columns;
    QVector<QStringList> rows;
    int affected = -1;
};

// Server metadata captured on a successful connect, so the console can populate
// the database switcher and object browser immediately. `objects` is a list of
// {"name": "schema.name", "type": "table"|"view"|"procedure"|"function"} maps.
struct SqlConnectInfo
{
    QStringList databases;
    QString currentDb;
    QVariantList objects;
};

// A database engine behind the SQL console. One instance is created by, lives
// on, and is only ever touched from a single SqlSession worker thread, so
// implementations need no locking. Two engines implement it: SQL Server via
// FreeTDS db-lib (TdsBackend) and PostgreSQL via libpq (PgBackend).
class SqlBackend
{
public:
    virtual ~SqlBackend() = default;

    // Opens a connection. Returns "" and fills `info` on success, or an error
    // message. The implementation keeps whatever it needs to reconnect for a
    // later switchDatabase().
    virtual QString open(const QString& host, int port, const QString& user,
                         const QString& password, const QString& database,
                         SqlConnectInfo& info) = 0;
    virtual void close() = 0;
    virtual bool isOpen() const = 0;

    // Runs one SQL batch, capturing every result set it produces (each SELECT
    // yields one; a non-row statement yields a column-less set carrying the
    // affected count). Returns false with `err` set on failure.
    virtual bool runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err) = 0;

    // Switches the active database and reloads its objects, filling the current
    // database name and object list. SQL Server issues USE; PostgreSQL, which
    // cannot change database on a live connection, reopens.
    virtual void switchDatabase(const QString& name, QString& currentDb, QVariantList& objects) = 0;

    // Fast metadata stats (no table scan) for one "schema.table"; each is -1
    // when unavailable.
    virtual void stats(const QString& table, qint64& rowCount, qint64& sizeKb) = 0;
};
