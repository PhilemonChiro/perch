#pragma once

#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include <atomic>

// One result set produced by a batch: its columns, its rows, and for a
// statement without a row set the affected-row count. A batch of several
// statements (e.g. two SELECTs) produces several of these.
struct SqlResultSet
{
    QStringList columns;
    QVector<QStringList> rows;
    int affected = -1;
};

// One line for the console's Messages pane: a server informational message
// (PRINT, RAISERROR severity <= 10, PostgreSQL NOTICE), a per-statement row
// count, or an error. `line` is the 1-based line within the batch the server
// attributes it to, or 0 when it gave none.
struct SqlMessage
{
    enum Kind { Info, RowCount, Error };
    Kind kind = Info;
    QString text;
    int line = 0;
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
    // True when the connection was open but the server or network dropped it.
    virtual bool isDead() const { return false; }

    // Runs one SQL batch, capturing every result set it produces (each SELECT
    // yields one; a non-row statement yields a column-less set carrying the
    // affected count) and, in order, the server messages and row counts it
    // reported. Returns false with `err` set on failure; a cancelled batch
    // also returns false, with cancelRequested() true.
    virtual bool runBatch(const QString& sql, QVector<SqlResultSet>& sets,
                          QVector<SqlMessage>& messages, QString& err) = 0;

    // Switches the active database and reloads its objects, filling the current
    // database name and object list. SQL Server issues USE; PostgreSQL, which
    // cannot change database on a live connection, reopens.
    virtual void switchDatabase(const QString& name, QString& currentDb, QVariantList& objects) = 0;

    // Re-reads the object browser list for the current database without changing
    // it — the manual "refresh" after the schema changes. No-op if not open.
    virtual void refreshObjects(QVariantList& objects) = 0;

    // Full schema for editor IntelliSense, in one map:
    //   tables:   {"schema.name": {type: "table"|"view", columns: [{name, type}]}}
    //   routines: {"schema.name": {type: "procedure"|"function",
    //              params: [{name, type, dir: "in"|"out"|"inout"}]}}
    //   fks:      [{from: "schema.t", fromCols: [..], to: "schema.t", toCols: [..]}]
    // Leaves `schema` empty if not open.
    virtual void schema(QVariantMap& schema) = 0;

    // Columns that identify a row of `table` ("schema.table", quoted or not):
    // its primary key, else its first unfiltered unique index; empty when it
    // has neither. `types`, when given, receives each column's lower-case base
    // type name in the same order.
    virtual QStringList primaryKey(const QString& table, QStringList* types = nullptr) = 0;

    // True while an explicit transaction is open on the connection, so callers
    // that need their own can nest a savepoint instead.
    virtual bool inTransaction() = 0;

    // Fast metadata stats (no table scan) for one "schema.table"; each is -1
    // when unavailable.
    virtual void stats(const QString& table, qint64& rowCount, qint64& sizeKb) = 0;

    // Seconds to wait on a server response before giving up (0 = forever).
    virtual void setQueryTimeout(int seconds) { Q_UNUSED(seconds); }

    // Cancellation — the only members that may be called from another thread
    // (the GUI), while the worker is blocked in runBatch(). requestCancel()
    // flags the batch and asks the engine to abort the running statement;
    // clearCancel() re-arms before the next run.
    void requestCancel()
    {
        m_cancelRequested.store(true);
        interrupt();
    }
    void clearCancel() { m_cancelRequested.store(false); }
    bool cancelRequested() const { return m_cancelRequested.load(); }

protected:
    // Engine-specific out-of-band cancel; runs on the calling (GUI) thread.
    virtual void interrupt() {}

    std::atomic<bool> m_cancelRequested { false };
};
