#include "SqlSession.h"

#include <QElapsedTimer>
#include <QMetaType>
#include <QObject>
#include <QRegularExpression>

#include <sybdb.h>
#include <sybfront.h>

// db-lib's error/message callbacks are global C functions with no user context
// except the DBPROCESS. We stash the active worker in a thread-local so the
// handlers can route text to it — safe because every db-lib call for a given
// connection runs on that connection's single worker thread, synchronously.
class SqlWorker;

namespace {

thread_local SqlWorker* t_current = nullptr;

int onDbError(DBPROCESS*, int, int dberr, int, char* dberrstr, char*);
int onDbMessage(DBPROCESS*, DBINT msgno, int, int severity, char* msgtext, char*, char*, int);

bool g_dbInited = false;

} // namespace

// The worker lives on its own QThread; all db-lib calls happen here.
class SqlWorker : public QObject
{
    Q_OBJECT
public:
    ~SqlWorker() override { closeProc(); }

public slots:
    void connectTo(const QString& host, int port, const QString& user,
                   const QString& password, const QString& database)
    {
        t_current = this;
        m_err.clear();
        closeProc();

        if (!g_dbInited) {
            if (dbinit() == FAIL) {
                emit failed(QStringLiteral("Could not initialise the database driver."));
                return;
            }
            dberrhandle(onDbError);
            dbmsghandle(onDbMessage);
            // Global (per-process) timeouts so an unreachable or wedged server
            // can never block the worker thread indefinitely — which would in
            // turn freeze the GUI thread when the session is torn down.
            dbsettime(60);     // seconds to wait on any server response
            g_dbInited = true;
        }

        // Bound the TCP login so dbopen() fails fast on an unreachable host
        // instead of stalling on the OS default connect timeout (~75s).
        dbsetlogintime(8);

        LOGINREC* login = dblogin();
        if (!login) {
            emit failed(QStringLiteral("Could not allocate a login record."));
            return;
        }
        DBSETLUSER(login, user.toUtf8().constData());
        DBSETLPWD(login, password.toUtf8().constData());
        DBSETLAPP(login, "Perch");
        DBSETLVERSION(login, DBVERSION_74); // SQL Server 2012+ speaks TDS 7.4.
        if (!database.isEmpty())
            DBSETLDBNAME(login, database.toUtf8().constData());

        const QByteArray server = (host + ':' + QString::number(port)).toUtf8();
        m_proc = dbopen(login, server.constData());
        dbloginfree(login);

        if (!m_proc) {
            emit failed(m_err.isEmpty()
                            ? QStringLiteral("Could not connect to %1.").arg(QString::fromUtf8(server))
                            : m_err.trimmed());
            return;
        }
        dbsetuserdata(m_proc, reinterpret_cast<BYTE*>(this));

        emit connected(databaseList(), currentDb(), tableList());
    }

    void switchTo(const QString& name)
    {
        t_current = this;
        if (!m_proc) {
            emit switched(currentDb(), tableList());
            return;
        }
        m_err.clear();
        // Bracket-quote the identifier, doubling any closing bracket.
        QString safe = name;
        safe.replace(QLatin1Char(']'), QStringLiteral("]]"));
        QStringList cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        runQuery(QStringLiteral("USE [%1]").arg(safe), cols, rows, affected, err);
        emit switched(currentDb(), tableList());
    }

    void run(const QString& sql)
    {
        t_current = this;
        if (!m_proc) {
            emit results({}, 0, QStringLiteral("Not connected."));
            return;
        }
        m_err.clear();
        QElapsedTimer timer;
        timer.start();

        QVector<SqlResultSet> sets;
        QString err;
        const bool ok = runBatch(sql, sets, err);
        const qint64 ms = timer.elapsed();

        emit results(sets, ms,
                     ok ? QString()
                        : (err.isEmpty() ? QStringLiteral("Query failed.") : err.trimmed()));
    }

    // Fetches fast metadata stats (no table scan) for one table on this same
    // worker thread, after the result grid is already shown.
    void statsFor(const QString& table)
    {
        t_current = this;
        if (!m_proc) {
            emit statsReady(table, -1, -1);
            return;
        }
        m_err.clear();
        QString esc = table;
        esc.replace(QLatin1Char('\''), QStringLiteral("''"));
        const QString q = QStringLiteral(
            "SELECT CAST(SUM(CASE WHEN index_id IN (0,1) THEN row_count ELSE 0 END) AS BIGINT), "
            "CAST(SUM(reserved_page_count) * 8 AS BIGINT) "
            "FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('%1')").arg(esc);
        QStringList cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        if (runQuery(q, cols, rows, affected, err) && !rows.isEmpty() && rows.first().size() >= 2) {
            bool ok1 = false, ok2 = false;
            const qint64 rc = rows.first().at(0).toLongLong(&ok1);
            const qint64 kb = rows.first().at(1).toLongLong(&ok2);
            emit statsReady(table, ok1 ? rc : -1, ok2 ? kb : -1);
        } else {
            emit statsReady(table, -1, -1);
        }
    }

    void shutdown() { closeProc(); }

signals:
    void connected(const QStringList& databases, const QString& currentDb, const QStringList& tables);
    void switched(const QString& currentDb, const QStringList& tables);
    void failed(const QString& error);
    void results(const QVector<SqlResultSet>& sets, qint64 elapsedMs, const QString& error);
    void statsReady(const QString& table, qint64 rowCount, qint64 sizeKb);

public:
    QString m_err; // appended to by the global handlers for the current call

private:
    void closeProc()
    {
        if (m_proc) {
            dbclose(m_proc);
            m_proc = nullptr;
        }
    }

    QStringList databaseList()
    {
        QStringList out, cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        if (runQuery(QStringLiteral("SELECT name FROM sys.databases WHERE state = 0 ORDER BY name"),
                     cols, rows, affected, err))
            for (const QStringList& r : rows)
                if (!r.isEmpty())
                    out << r.first();
        return out;
    }

    QString currentDb()
    {
        QStringList cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        if (runQuery(QStringLiteral("SELECT DB_NAME()"), cols, rows, affected, err)
            && !rows.isEmpty() && !rows.first().isEmpty())
            return rows.first().first();
        return {};
    }

    QStringList tableList()
    {
        QStringList out, cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        if (runQuery(QStringLiteral(
                         "SELECT TABLE_SCHEMA + '.' + TABLE_NAME FROM INFORMATION_SCHEMA.TABLES "
                         "WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') ORDER BY TABLE_SCHEMA, TABLE_NAME"),
                     cols, rows, affected, err))
            for (const QStringList& r : rows)
                if (!r.isEmpty())
                    out << r.first();
        return out;
    }

    // Runs one SQL batch. Returns the first result set that has columns (later
    // sets are drained), or no columns with `affected` set for a non-SELECT.
    bool runQuery(const QString& sql, QStringList& columns, QVector<QStringList>& rows,
                  int& affected, QString& err)
    {
        if (dbcmd(m_proc, sql.toUtf8().constData()) == FAIL || dbsqlexec(m_proc) == FAIL) {
            err = m_err;
            return false;
        }
        bool captured = false;
        RETCODE rc;
        while ((rc = dbresults(m_proc)) != NO_MORE_RESULTS) {
            if (rc == FAIL) {
                err = m_err;
                return false;
            }
            const int ncols = dbnumcols(m_proc);
            if (ncols > 0 && !captured) {
                for (int c = 1; c <= ncols; ++c)
                    columns << QString::fromUtf8(dbcolname(m_proc, c));
                while (dbnextrow(m_proc) != NO_MORE_ROWS) {
                    QStringList row;
                    row.reserve(ncols);
                    for (int c = 1; c <= ncols; ++c)
                        row << cell(c);
                    rows << row;
                }
                captured = true;
            } else {
                while (dbnextrow(m_proc) != NO_MORE_ROWS) { }
            }
            const DBINT n = DBCOUNT(m_proc);
            if (n >= 0)
                affected = int(n);
        }
        return true;
    }

    // Runs a batch and captures every result set it produces (each SELECT yields
    // one; non-row statements yield a column-less set carrying the affected count).
    bool runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err)
    {
        if (dbcmd(m_proc, sql.toUtf8().constData()) == FAIL || dbsqlexec(m_proc) == FAIL) {
            err = m_err;
            return false;
        }
        RETCODE rc;
        while ((rc = dbresults(m_proc)) != NO_MORE_RESULTS) {
            if (rc == FAIL) {
                err = m_err;
                return false;
            }
            const int ncols = dbnumcols(m_proc);
            SqlResultSet set;
            if (ncols > 0) {
                for (int c = 1; c <= ncols; ++c)
                    set.columns << QString::fromUtf8(dbcolname(m_proc, c));
                while (dbnextrow(m_proc) != NO_MORE_ROWS) {
                    QStringList row;
                    row.reserve(ncols);
                    for (int c = 1; c <= ncols; ++c)
                        row << cell(c);
                    set.rows << row;
                }
            } else {
                while (dbnextrow(m_proc) != NO_MORE_ROWS) { }
            }
            const DBINT n = DBCOUNT(m_proc);
            set.affected = n >= 0 ? int(n) : -1;
            sets << set;
        }
        return true;
    }

    // Converts the current row's column `c` to text; a true SQL NULL becomes a
    // null QString (rendered as "NULL" by the view).
    QString cell(int c)
    {
        BYTE* src = dbdata(m_proc, c);
        const DBINT len = dbdatlen(m_proc, c);
        if (!src)
            return {}; // SQL NULL
        if (len == 0)
            return QString(QLatin1String("")); // empty string, not NULL
        const int coltype = dbcoltype(m_proc, c);
        QByteArray buf(int(len) * 2 + 256, '\0');
        const DBINT n = dbconvert(m_proc, coltype, src, len, SYBCHAR,
                                  reinterpret_cast<BYTE*>(buf.data()), -1);
        if (n < 0)
            return QStringLiteral("<?>");
        return QString::fromUtf8(buf.constData());
    }

    DBPROCESS* m_proc = nullptr;
};

namespace {

int onDbError(DBPROCESS* proc, int, int dberr, int, char* dberrstr, char*)
{
    SqlWorker* w = t_current;
    if (proc)
        if (BYTE* u = dbgetuserdata(proc))
            w = reinterpret_cast<SqlWorker*>(u);
    if (w && dberrstr && *dberrstr) {
        if (!w->m_err.isEmpty())
            w->m_err += QLatin1Char('\n');
        w->m_err += QString::fromUtf8(dberrstr);
    }
    Q_UNUSED(dberr);
    return INT_CANCEL;
}

int onDbMessage(DBPROCESS* proc, DBINT msgno, int, int severity, char* msgtext, char*, char*, int)
{
    // Severity > 10 is a real error; lower is informational.
    if (severity > 10 && msgtext && *msgtext) {
        SqlWorker* w = t_current;
        if (proc)
            if (BYTE* u = dbgetuserdata(proc))
                w = reinterpret_cast<SqlWorker*>(u);
        if (w) {
            if (!w->m_err.isEmpty())
                w->m_err += QLatin1Char('\n');
            w->m_err += QString::fromUtf8(msgtext);
        }
    }
    Q_UNUSED(msgno);
    return 0;
}

} // namespace

// ---- SqlSession (GUI thread) ----

SqlSession::SqlSession(const QString& hostId, const QString& host, int port,
                       const QString& username, const QString& database, QObject* parent)
    : QObject(parent)
    , m_hostId(hostId)
    , m_title(host)
    , m_host(host)
    , m_port(port)
    , m_username(username)
    , m_database(database)
    , m_currentDatabase(database)
    , m_result(new SqlResultModel(this))
{
    qRegisterMetaType<QVector<QStringList>>("QVector<QStringList>");
    qRegisterMetaType<QVector<SqlResultSet>>("QVector<SqlResultSet>");

    m_idleTimer.setSingleShot(true);
    connect(&m_idleTimer, &QTimer::timeout, this, [this] {
        if (m_state == Connected) {
            QMetaObject::invokeMethod(m_worker, "shutdown", Qt::QueuedConnection);
            m_statusText = QStringLiteral("Paused after inactivity — run a query to resume.");
            emit statusChanged();
            setState(Paused);
        }
    });

    m_worker = new SqlWorker;
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &SqlSession::doConnect, m_worker, &SqlWorker::connectTo);
    connect(this, &SqlSession::doExecute, m_worker, &SqlWorker::run);
    connect(this, &SqlSession::doUseDatabase, m_worker, &SqlWorker::switchTo);
    connect(this, &SqlSession::doStats, m_worker, &SqlWorker::statsFor);
    connect(m_worker, &SqlWorker::connected, this, &SqlSession::onConnected);
    connect(m_worker, &SqlWorker::switched, this, &SqlSession::onSwitched);
    connect(m_worker, &SqlWorker::failed, this, &SqlSession::onFailed);
    connect(m_worker, &SqlWorker::results, this, &SqlSession::onResults);
    connect(m_worker, &SqlWorker::statsReady, this, &SqlSession::onStats);
    m_thread.start();
}

SqlSession::~SqlSession()
{
    QMetaObject::invokeMethod(m_worker, "shutdown", Qt::BlockingQueuedConnection);
    m_thread.quit();
    m_thread.wait();
}

int SqlSession::phase() const
{
    switch (m_state) {
    case Connecting: return PhaseConnecting;
    case Connected: return PhaseLive;
    case Executing: return PhaseBusy;
    case Paused: return PhaseEnded;
    case Disconnected: return PhaseEnded;
    case Failed: return PhaseFailed;
    case Idle:
    default: return PhaseIdle;
    }
}

void SqlSession::setState(State s)
{
    if (m_state == s)
        return;
    m_state = s;
    emit stateChanged();
}

void SqlSession::kickIdle()
{
    if (m_idleTimeout > 0)
        m_idleTimer.start(m_idleTimeout);
    else
        m_idleTimer.stop();
}

void SqlSession::setIdleTimeout(int ms)
{
    m_idleTimeout = ms;
    if (m_state == Connected)
        kickIdle();
}

void SqlSession::connectWith(const QString& password, bool remember)
{
    if (m_state == Connecting || m_state == Connected || m_state == Executing)
        return;
    m_password = password;
    m_remember = remember;
    m_errorText.clear();
    emit errorChanged();
    m_statusText = QStringLiteral("Connecting…");
    emit statusChanged();
    setState(Connecting);
    emit doConnect(m_host, m_port, m_username, m_password, m_currentDatabase);
}

void SqlSession::reconnect()
{
    if (m_password.isEmpty()) {
        setState(Idle); // never connected — surface the gate again
        return;
    }
    if (m_state == Connecting || m_state == Connected || m_state == Executing)
        return;
    m_errorText.clear();
    emit errorChanged();
    m_statusText = QStringLiteral("Resuming…");
    emit statusChanged();
    setState(Connecting);
    emit doConnect(m_host, m_port, m_username, m_password, m_currentDatabase);
}

QString SqlSession::sourceTable(const QString& sql)
{
    const QString s = sql.trimmed();
    static const QRegularExpression sel(QStringLiteral("^select\\b"),
                                        QRegularExpression::CaseInsensitiveOption);
    if (!sel.match(s).hasMatch())
        return {};
    static const QRegularExpression join(QStringLiteral("\\bjoin\\b"),
                                         QRegularExpression::CaseInsensitiveOption);
    if (s.contains(join))
        return {};
    // db.schema.table (1–3 dotted, optionally bracketed) right after FROM.
    static const QRegularExpression from(
        QStringLiteral("\\bfrom\\s+(\\[?[A-Za-z_@#][\\w$]*\\]?(?:\\.\\[?[A-Za-z_@#][\\w$]*\\]?){0,2})"),
        QRegularExpression::CaseInsensitiveOption);
    const auto m = from.match(s);
    if (!m.hasMatch())
        return {};
    // Reject comma-separated (old-style multi-table) FROM lists.
    const QString afterFrom = s.mid(m.capturedEnd(1));
    static const QRegularExpression nextClause(
        QStringLiteral("\\b(where|group|order|having|union|for|option)\\b"),
        QRegularExpression::CaseInsensitiveOption);
    const auto nc = nextClause.match(afterFrom);
    const QString fromTail = nc.hasMatch() ? afterFrom.left(nc.capturedStart(0)) : afterFrom;
    if (fromTail.contains(QLatin1Char(',')))
        return {};
    // A table read, not a function/derived table.
    QString t = m.captured(1);
    if (t.contains(QLatin1Char('(')))
        return {};
    return t;
}

void SqlSession::execute(const QString& sql)
{
    if (sql.trimmed().isEmpty())
        return;
    m_batchSql = sql;
    // Reset table stats; refetched after the result if this is a single-table read.
    m_pendingStatsTable = sourceTable(sql);
    if (!m_statsTable.isEmpty() || m_tableRowCount >= 0 || m_tableSizeKb >= 0) {
        m_statsTable.clear();
        m_tableRowCount = -1;
        m_tableSizeKb = -1;
        emit statsChanged();
    }
    if (m_state == Paused || m_state == Disconnected || m_state == Failed) {
        m_pendingSql = sql; // resume: reconnect, then run once live
        reconnect();
        return;
    }
    if (m_state != Connected && m_state != Executing)
        return;
    m_statusText = QStringLiteral("Running…");
    emit statusChanged();
    setState(Executing);
    kickIdle();
    emit doExecute(sql);
}

void SqlSession::useDatabase(const QString& name)
{
    if (name.isEmpty() || name == m_currentDatabase)
        return;
    m_currentDatabase = name;
    emit currentDatabaseChanged();
    if (m_state == Paused || m_state == Disconnected || m_state == Failed) {
        reconnect(); // reconnect lands in the newly selected database
        return;
    }
    if (m_state != Connected)
        return;
    kickIdle();
    emit doUseDatabase(name);
}

void SqlSession::disconnectSession()
{
    m_idleTimer.stop();
    QMetaObject::invokeMethod(m_worker, "shutdown", Qt::QueuedConnection);
    m_statusText = QStringLiteral("Disconnected.");
    emit statusChanged();
    setState(Disconnected);
}

void SqlSession::onConnected(const QStringList& databases, const QString& currentDb,
                             const QStringList& tables)
{
    m_haveConnected = true;
    m_databases = databases;
    emit databasesChanged();
    if (!currentDb.isEmpty() && currentDb != m_currentDatabase) {
        m_currentDatabase = currentDb;
        emit currentDatabaseChanged();
    }
    m_tables = tables;
    emit tablesChanged();
    m_statusText = QStringLiteral("Connected.");
    emit statusChanged();
    setState(Connected);
    kickIdle();

    // Persist the password now that we know it works, if asked.
    if (m_remember && !m_hostId.isEmpty() && !m_password.isEmpty())
        emit rememberPassword(m_password);

    if (!m_pendingSql.isEmpty()) {
        const QString sql = m_pendingSql;
        m_pendingSql.clear();
        execute(sql);
    }
}

void SqlSession::onSwitched(const QString& currentDb, const QStringList& tables)
{
    if (!currentDb.isEmpty() && currentDb != m_currentDatabase) {
        m_currentDatabase = currentDb;
        emit currentDatabaseChanged();
    }
    m_tables = tables;
    emit tablesChanged();
    kickIdle();
}

void SqlSession::onFailed(const QString& error)
{
    m_pendingSql.clear();
    m_errorText = error;
    emit errorChanged();
    m_statusText = QStringLiteral("Connection failed.");
    emit statusChanged();
    setState(Failed);
}

QVariantList SqlSession::resultModels() const
{
    QVariantList out;
    if (m_sets.isEmpty())
        return out;
    out.append(QVariant::fromValue(static_cast<QObject*>(m_result)));
    for (SqlResultModel* m : m_extraModels)
        out.append(QVariant::fromValue(static_cast<QObject*>(m)));
    return out;
}

void SqlSession::rebuildModels()
{
    for (SqlResultModel* m : std::as_const(m_extraModels))
        m->deleteLater();
    m_extraModels.clear();

    if (m_sets.isEmpty()) {
        m_result->reset({}, {});
        return;
    }
    m_result->reset(m_sets.at(0).columns, m_sets.at(0).rows);
    for (int i = 1; i < m_sets.size(); ++i) {
        auto* m = new SqlResultModel(this);
        m->reset(m_sets.at(i).columns, m_sets.at(i).rows);
        m_extraModels.append(m);
    }
}

void SqlSession::onResults(const QVector<SqlResultSet>& sets, qint64 elapsed, const QString& error)
{
    m_elapsed = elapsed;

    // Split into grid sets (with columns) and a running tally of affected rows
    // from the statements that returned none.
    m_sets.clear();
    int affected = -1;
    for (const SqlResultSet& s : sets) {
        if (!s.columns.isEmpty())
            m_sets << s;
        else if (s.affected >= 0)
            affected = (affected < 0 ? 0 : affected) + s.affected;
    }
    m_affected = affected;

    if (!error.isEmpty()) {
        m_sets.clear();
        rebuildModels();
        emit resultsChanged();
        m_message.clear();
        emit messageChanged();
        m_errorText = error;
        emit errorChanged();
        m_statusText = QStringLiteral("Query failed.");
        emit statusChanged();
        setState(Connected);
        kickIdle();
        return;
    }

    rebuildModels();
    emit resultsChanged();

    m_errorText.clear();
    emit errorChanged();

    if (m_sets.isEmpty()) {
        // A batch that returned no rows (e.g. UPDATE/INSERT/DDL).
        m_message = affected >= 0 ? QObject::tr("%n row(s) affected", nullptr, affected)
                                  : QStringLiteral("Command completed.");
        emit messageChanged();
        m_statusText = m_message;
        emit statusChanged();
    } else {
        m_message.clear();
        emit messageChanged();
        const int shown = m_result->rowCountProp();
        m_statusText = QObject::tr("%n row(s)", nullptr, shown)
                       + QStringLiteral(" · %1 ms").arg(elapsed);
        emit statusChanged();
    }

    setState(Connected);
    kickIdle();

    // Background table-stats only make sense for a lone single-table SELECT.
    if (m_sets.size() == 1 && !m_pendingStatsTable.isEmpty())
        emit doStats(m_pendingStatsTable);
}

void SqlSession::onStats(const QString& table, qint64 rowCount, qint64 sizeKb)
{
    if (table != m_pendingStatsTable) // a newer query superseded this request
        return;
    m_statsTable = table;
    m_tableRowCount = rowCount;
    m_tableSizeKb = sizeKb;
    emit statsChanged();
}

#include "SqlSession.moc"
