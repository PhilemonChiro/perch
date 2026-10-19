#include "TdsBackend.h"

#include <QString>
#include <QVariantMap>

#include <sybdb.h>
#include <sybfront.h>

// db-lib's error/message callbacks are global C functions with no user context
// except the DBPROCESS. We stash the active backend in a thread-local so the
// handlers can route text to it — safe because every db-lib call for a given
// connection runs on that connection's single worker thread, synchronously.
namespace {

thread_local TdsBackend* t_current = nullptr;
bool g_dbInited = false;

int onDbError(DBPROCESS* proc, int, int dberr, int, char* dberrstr, char*)
{
    TdsBackend* b = t_current;
    if (proc)
        if (BYTE* u = dbgetuserdata(proc))
            b = reinterpret_cast<TdsBackend*>(u);
    if (b && dberrstr && *dberrstr) {
        if (!b->m_err.isEmpty())
            b->m_err += QLatin1Char('\n');
        b->m_err += QString::fromUtf8(dberrstr);
    }
    Q_UNUSED(dberr);
    return INT_CANCEL;
}

int onDbMessage(DBPROCESS* proc, DBINT msgno, int, int severity, char* msgtext, char*, char*, int)
{
    // Severity > 10 is a real error; lower is informational.
    if (severity > 10 && msgtext && *msgtext) {
        TdsBackend* b = t_current;
        if (proc)
            if (BYTE* u = dbgetuserdata(proc))
                b = reinterpret_cast<TdsBackend*>(u);
        if (b) {
            if (!b->m_err.isEmpty())
                b->m_err += QLatin1Char('\n');
            b->m_err += QString::fromUtf8(msgtext);
        }
    }
    Q_UNUSED(msgno);
    return 0;
}

} // namespace

TdsBackend::~TdsBackend()
{
    close();
}

void TdsBackend::close()
{
    if (m_proc) {
        dbclose(m_proc);
        m_proc = nullptr;
    }
}

QString TdsBackend::open(const QString& host, int port, const QString& user,
                         const QString& password, const QString& database,
                         SqlConnectInfo& info)
{
    t_current = this;
    m_err.clear();
    close();

    if (!g_dbInited) {
        if (dbinit() == FAIL)
            return QStringLiteral("Could not initialise the database driver.");
        dberrhandle(onDbError);
        dbmsghandle(onDbMessage);
        // Global (per-process) timeouts so an unreachable or wedged server can
        // never block the worker thread indefinitely — which would in turn
        // freeze the GUI thread when the session is torn down.
        dbsettime(60);     // seconds to wait on any server response
        g_dbInited = true;
    }

    // Bound the TCP login so dbopen() fails fast on an unreachable host instead
    // of stalling on the OS default connect timeout (~75s).
    dbsetlogintime(8);

    LOGINREC* login = dblogin();
    if (!login)
        return QStringLiteral("Could not allocate a login record.");
    DBSETLUSER(login, user.toUtf8().constData());
    DBSETLPWD(login, password.toUtf8().constData());
    DBSETLAPP(login, "Perch");
    DBSETLVERSION(login, DBVERSION_74); // SQL Server 2012+ speaks TDS 7.4.
    if (!database.isEmpty())
        DBSETLDBNAME(login, database.toUtf8().constData());

    const QByteArray server = (host + ':' + QString::number(port)).toUtf8();
    m_proc = dbopen(login, server.constData());
    dbloginfree(login);

    if (!m_proc)
        return m_err.isEmpty()
                   ? QStringLiteral("Could not connect to %1.").arg(QString::fromUtf8(server))
                   : m_err.trimmed();
    dbsetuserdata(m_proc, reinterpret_cast<BYTE*>(this));

    info.databases = databaseList();
    info.currentDb = currentDb();
    info.objects = objectList();
    return {};
}

void TdsBackend::switchDatabase(const QString& name, QString& currentDb, QVariantList& objects)
{
    t_current = this;
    if (!m_proc) {
        currentDb = this->currentDb();
        objects = objectList();
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
    currentDb = this->currentDb();
    objects = objectList();
}

void TdsBackend::stats(const QString& table, qint64& rowCount, qint64& sizeKb)
{
    t_current = this;
    rowCount = -1;
    sizeKb = -1;
    if (!m_proc)
        return;
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
        rowCount = ok1 ? rc : -1;
        sizeKb = ok2 ? kb : -1;
    }
}

QStringList TdsBackend::databaseList()
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

QString TdsBackend::currentDb()
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

// Every browsable object — tables, views, stored procedures and functions —
// each as {"name": "schema.name", "type": ...}, ordered by type then name.
QVariantList TdsBackend::objectList()
{
    QVariantList out;
    QStringList cols;
    QVector<QStringList> rows;
    int affected = -1;
    QString err;
    if (runQuery(QStringLiteral(
                     "SELECT s.name + '.' + o.name, "
                     "CASE o.type WHEN 'U' THEN 'table' WHEN 'V' THEN 'view' "
                     "WHEN 'P' THEN 'procedure' ELSE 'function' END "
                     "FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id "
                     "WHERE o.type IN ('U','V','P','FN','IF','TF') AND o.is_ms_shipped = 0 "
                     "ORDER BY CASE o.type WHEN 'U' THEN 0 WHEN 'V' THEN 1 WHEN 'P' THEN 2 ELSE 3 END, "
                     "s.name, o.name"),
                 cols, rows, affected, err))
        for (const QStringList& r : rows)
            if (r.size() >= 2 && !r.first().isEmpty())
                out.append(QVariantMap{ { QStringLiteral("name"), r.at(0) },
                                        { QStringLiteral("type"), r.at(1) } });
    return out;
}

bool TdsBackend::runQuery(const QString& sql, QStringList& columns, QVector<QStringList>& rows,
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

bool TdsBackend::runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err)
{
    t_current = this;
    if (!m_proc) {
        err = QStringLiteral("Not connected.");
        return false;
    }
    m_err.clear();
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

// Converts the current row's column `c` to text; a true SQL NULL becomes a null
// QString (rendered as "NULL" by the view).
QString TdsBackend::cell(int c)
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
