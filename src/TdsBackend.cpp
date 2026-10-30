#include "TdsBackend.h"

#include <QObject>
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

TdsBackend* backendFor(DBPROCESS* proc)
{
    TdsBackend* b = t_current;
    if (proc)
        if (BYTE* u = dbgetuserdata(proc))
            b = reinterpret_cast<TdsBackend*>(u);
    return b;
}

int onDbError(DBPROCESS* proc, int, int dberr, int, char* dberrstr, char*)
{
    TdsBackend* b = backendFor(proc);
    if (b && dberrstr && *dberrstr) {
        if (!b->m_err.isEmpty())
            b->m_err += QLatin1Char('\n');
        b->m_err += QString::fromUtf8(dberrstr);
        // SYBESMSG only says "check messages from the server", which the message
        // handler already recorded; a cancel's own fallout is not news either.
        if (b->m_msgs && dberr != SYBESMSG && !b->cancelRequested())
            b->m_msgs->append({ SqlMessage::Error, QString::fromUtf8(dberrstr), 0 });
    }
    return INT_CANCEL;
}

int onDbMessage(DBPROCESS* proc, DBINT msgno, int, int severity, char* msgtext, char*, char*, int line)
{
    if (!msgtext || !*msgtext)
        return 0;
    TdsBackend* b = backendFor(proc);
    if (!b)
        return 0;
    const QString text = QString::fromUtf8(msgtext);
    // Severity > 10 is a real error; lower is informational.
    if (severity > 10) {
        if (!b->m_err.isEmpty())
            b->m_err += QLatin1Char('\n');
        b->m_err += line > 0 ? QStringLiteral("Line %1: %2").arg(line).arg(text) : text;
        if (b->m_msgs && !b->cancelRequested())
            b->m_msgs->append({ SqlMessage::Error,
                                QStringLiteral("Msg %1, Level %2: %3").arg(msgno).arg(severity).arg(text),
                                line });
    } else if (b->m_msgs && msgno != 5701 && msgno != 5703) {
        // PRINT / RAISERROR(..., 0-10). 5701/5703 are the "changed database
        // context / language" chatter every login and USE produces.
        b->m_msgs->append({ SqlMessage::Info, text, line });
    }
    return 0;
}

// db-lib polls chkintr about once a second while it waits on the server; when
// it reports a pending interrupt, hndlintr's INT_CANCEL makes db-lib send a TDS
// cancel and fail the call, leaving the connection usable.
int onCheckInterrupt(void* proc)
{
    TdsBackend* b = backendFor(static_cast<DBPROCESS*>(proc));
    return (b && b->cancelRequested()) ? TRUE : FALSE;
}

int onHandleInterrupt(void*)
{
    return INT_CANCEL;
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
        // Global (per-process) response timeout so a wedged server can never
        // block the worker thread forever — which would in turn freeze the GUI
        // thread when the session is torn down. Long, since a running query can
        // now be cancelled; SqlSession may change it via setQueryTimeout().
        dbsettime(30 * 60);
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
    dbsetinterrupt(m_proc, onCheckInterrupt, onHandleInterrupt);

    // db-lib logs in with the ANSI options off, unlike SSMS/ODBC. Writes to
    // tables with indexed views, filtered indexes or indexed computed columns
    // then fail with "SET options have incorrect settings". Match SSMS.
    {
        QStringList cols;
        QVector<QStringList> rows;
        int affected = -1;
        QString err;
        runQuery(QStringLiteral(
                     "SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; "
                     "SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; "
                     "SET QUOTED_IDENTIFIER ON; SET NUMERIC_ROUNDABORT OFF;"),
                 cols, rows, affected, err);
        // A connection the server dropped straight after login fails the
        // connect (and so gets the usual retry) rather than opening a tab that
        // shows no objects and errors on every query.
        if (DBDEAD(m_proc)) {
            const QString why = m_err.trimmed();
            close();
            return why.isEmpty() ? QStringLiteral("The server closed the connection.") : why;
        }
        m_err.clear();
    }

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
                     "WHEN 'P' THEN 'procedure' ELSE 'function' END, "
                     // Comma-separated input-parameter signature (procedures/functions only).
                     "STUFF((SELECT ', ' + p.name + ' ' + TYPE_NAME(p.user_type_id) "
                     "       FROM sys.parameters p "
                     "       WHERE p.object_id = o.object_id AND p.parameter_id > 0 AND p.is_output = 0 "
                     "       ORDER BY p.parameter_id FOR XML PATH('')), 1, 2, '') "
                     "FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id "
                     "WHERE o.type IN ('U','V','P','FN','IF','TF') AND o.is_ms_shipped = 0 "
                     "ORDER BY CASE o.type WHEN 'U' THEN 0 WHEN 'V' THEN 1 WHEN 'P' THEN 2 ELSE 3 END, "
                     "s.name, o.name"),
                 cols, rows, affected, err))
        for (const QStringList& r : rows)
            if (r.size() >= 2 && !r.first().isEmpty())
                out.append(QVariantMap{ { QStringLiteral("name"), r.at(0) },
                                        { QStringLiteral("type"), r.at(1) },
                                        { QStringLiteral("args"), r.size() >= 3 ? r.at(2) : QString() } });
    return out;
}

bool TdsBackend::runQuery(const QString& sql, QStringList& columns, QVector<QStringList>& rows,
                          int& affected, QString& err)
{
    // Discard anything a previous command left unread; otherwise db-lib refuses
    // the next command with "results pending".
    dbcancel(m_proc);
    if (dbcmd(m_proc, sql.toUtf8().constData()) == FAIL || dbsqlexec(m_proc) == FAIL) {
        err = m_err;
        dbcancel(m_proc);
        return false;
    }
    bool captured = false;
    RETCODE rc;
    while ((rc = dbresults(m_proc)) != NO_MORE_RESULTS) {
        if (rc == FAIL) {
            err = m_err;
            dbcancel(m_proc); // drop the rest of the batch's results
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

bool TdsBackend::runBatch(const QString& sql, QVector<SqlResultSet>& sets,
                          QVector<SqlMessage>& messages, QString& err)
{
    t_current = this;
    if (!m_proc) {
        err = QStringLiteral("Not connected.");
        return false;
    }
    m_err.clear();
    // Discard anything a previous command left unread; otherwise db-lib refuses
    // the next command with "results pending".
    dbcancel(m_proc);
    m_msgs = &messages;
    const auto fail = [&] {
        err = m_err;
        dbcancel(m_proc); // drop the rest of the batch's results
        m_msgs = nullptr;
        return false;
    };
    if (dbcmd(m_proc, sql.toUtf8().constData()) == FAIL || dbsqlexec(m_proc) == FAIL)
        return fail();
    RETCODE rc;
    while ((rc = dbresults(m_proc)) != NO_MORE_RESULTS) {
        if (rc == FAIL || cancelRequested())
            return fail();
        const int ncols = dbnumcols(m_proc);
        SqlResultSet set;
        if (ncols > 0) {
            for (int c = 1; c <= ncols; ++c)
                set.columns << QString::fromUtf8(dbcolname(m_proc, c));
            while (dbnextrow(m_proc) != NO_MORE_ROWS) {
                if (cancelRequested())
                    return fail();
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
        if (n >= 0)
            messages.append({ SqlMessage::RowCount,
                              QObject::tr("(%n row(s) affected)", nullptr, int(n)), 0 });
        sets << set;
    }
    m_msgs = nullptr;
    return true;
}

void TdsBackend::setQueryTimeout(int seconds)
{
    // db-lib's response timeout is process-wide, not per connection.
    dbsettime(seconds > 0 ? seconds : 0);
}

bool TdsBackend::inTransaction()
{
    t_current = this;
    if (!m_proc)
        return false;
    QStringList cols;
    QVector<QStringList> rows;
    int affected = -1;
    QString err;
    return runQuery(QStringLiteral("SELECT @@TRANCOUNT"), cols, rows, affected, err)
           && !rows.isEmpty() && !rows.first().isEmpty() && rows.first().first().toInt() > 0;
}

QStringList TdsBackend::primaryKey(const QString& table, QStringList* types)
{
    t_current = this;
    QStringList out;
    if (!m_proc)
        return out;
    m_err.clear();
    QString esc = table;
    esc.replace(QLatin1Char('\''), QStringLiteral("''"));
    // The primary key if there is one, else the lowest-id enabled, unfiltered
    // unique index; key columns only (not INCLUDEs), in key order.
    const QString q = QStringLiteral(
        "SELECT c.name, LOWER(TYPE_NAME(c.system_type_id)) "
        "FROM sys.index_columns ic "
        "JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id "
        "WHERE ic.object_id = OBJECT_ID(N'%1') AND ic.is_included_column = 0 AND ic.index_id = ("
        "  SELECT TOP 1 i.index_id FROM sys.indexes i "
        "  WHERE i.object_id = OBJECT_ID(N'%1') AND i.is_disabled = 0 "
        "    AND (i.is_primary_key = 1 OR (i.is_unique = 1 AND i.has_filter = 0)) "
        "  ORDER BY i.is_primary_key DESC, i.index_id) "
        "ORDER BY ic.key_ordinal").arg(esc);
    QStringList cols;
    QVector<QStringList> rows;
    int affected = -1;
    QString err;
    if (runQuery(q, cols, rows, affected, err))
        for (const QStringList& r : rows)
            if (r.size() >= 2) {
                out << r.at(0);
                if (types)
                    *types << r.at(1);
            }
    return out;
}

void TdsBackend::schema(QVariantMap& schema)
{
    t_current = this;
    schema.clear();
    if (!m_proc)
        return;
    m_err.clear();
    QStringList cols;
    int affected = -1;
    QString err;

    // Tables/views with typed columns, in definition order.
    QVariantMap tables;
    QVector<QStringList> rows;
    if (runQuery(QStringLiteral(
                     "SELECT s.name + '.' + o.name, CASE o.type WHEN 'V' THEN 'view' ELSE 'table' END, "
                     "c.name, TYPE_NAME(c.user_type_id) + CASE "
                     "  WHEN TYPE_NAME(c.user_type_id) IN ('varchar','char','varbinary','binary') "
                     "    THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar(10)) END + ')' "
                     "  WHEN TYPE_NAME(c.user_type_id) IN ('nvarchar','nchar') "
                     "    THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar(10)) END + ')' "
                     "  WHEN TYPE_NAME(c.user_type_id) IN ('decimal','numeric') "
                     "    THEN '(' + CAST(c.precision AS varchar(5)) + ',' + CAST(c.scale AS varchar(5)) + ')' "
                     "  ELSE '' END "
                     "FROM sys.columns c "
                     "JOIN sys.objects o ON o.object_id = c.object_id "
                     "JOIN sys.schemas s ON s.schema_id = o.schema_id "
                     "WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0 "
                     "ORDER BY o.object_id, c.column_id"),
                 cols, rows, affected, err)) {
        for (const QStringList& r : std::as_const(rows)) {
            if (r.size() < 4 || r.first().isEmpty())
                continue;
            QVariantMap t = tables.value(r.at(0)).toMap();
            QVariantList list = t.value(QStringLiteral("columns")).toList();
            list.append(QVariantMap{ { QStringLiteral("name"), r.at(2) }, { QStringLiteral("type"), r.at(3) } });
            t.insert(QStringLiteral("type"), r.at(1));
            t.insert(QStringLiteral("columns"), list);
            tables.insert(r.at(0), t);
        }
    }

    // Procedures/functions with their parameters, in declaration order. A
    // routine without parameters still appears (LEFT JOIN, empty name).
    QVariantMap routines;
    rows.clear();
    cols.clear();
    if (runQuery(QStringLiteral(
                     "SELECT s.name + '.' + o.name, CASE o.type WHEN 'P' THEN 'procedure' ELSE 'function' END, "
                     "ISNULL(p.name, ''), ISNULL(TYPE_NAME(p.user_type_id), ''), ISNULL(CAST(p.is_output AS int), 0) "
                     "FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id "
                     "LEFT JOIN sys.parameters p ON p.object_id = o.object_id AND p.parameter_id > 0 "
                     "WHERE o.type IN ('P','FN','IF','TF') AND o.is_ms_shipped = 0 "
                     "ORDER BY o.object_id, p.parameter_id"),
                 cols, rows, affected, err)) {
        for (const QStringList& r : std::as_const(rows)) {
            if (r.size() < 5 || r.first().isEmpty())
                continue;
            QVariantMap rt = routines.value(r.at(0)).toMap();
            QVariantList params = rt.value(QStringLiteral("params")).toList();
            if (!r.at(2).isEmpty())
                params.append(QVariantMap{ { QStringLiteral("name"), r.at(2) },
                                           { QStringLiteral("type"), r.at(3) },
                                           { QStringLiteral("dir"), r.at(4).toInt() ? QStringLiteral("out")
                                                                                     : QStringLiteral("in") } });
            rt.insert(QStringLiteral("type"), r.at(1));
            rt.insert(QStringLiteral("params"), params);
            routines.insert(r.at(0), rt);
        }
    }

    // Foreign keys, one entry per constraint with its column pairs in order.
    QVariantList fks;
    rows.clear();
    cols.clear();
    if (runQuery(QStringLiteral(
                     "SELECT CAST(fkc.constraint_object_id AS varchar(20)), "
                     "SCHEMA_NAME(pt.schema_id) + '.' + pt.name, pc.name, "
                     "SCHEMA_NAME(rt.schema_id) + '.' + rt.name, rc.name "
                     "FROM sys.foreign_key_columns fkc "
                     "JOIN sys.tables pt ON pt.object_id = fkc.parent_object_id "
                     "JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id "
                     "JOIN sys.tables rt ON rt.object_id = fkc.referenced_object_id "
                     "JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id "
                     "ORDER BY fkc.constraint_object_id, fkc.constraint_column_id"),
                 cols, rows, affected, err)) {
        QString lastId;
        QVariantMap cur;
        QStringList fromCols, toCols;
        const auto flush = [&] {
            if (lastId.isEmpty())
                return;
            cur.insert(QStringLiteral("fromCols"), fromCols);
            cur.insert(QStringLiteral("toCols"), toCols);
            fks.append(cur);
        };
        for (const QStringList& r : std::as_const(rows)) {
            if (r.size() < 5)
                continue;
            if (r.at(0) != lastId) {
                flush();
                lastId = r.at(0);
                cur = QVariantMap{ { QStringLiteral("from"), r.at(1) }, { QStringLiteral("to"), r.at(3) } };
                fromCols.clear();
                toCols.clear();
            }
            fromCols << r.at(2);
            toCols << r.at(4);
        }
        flush();
    }

    schema.insert(QStringLiteral("tables"), tables);
    schema.insert(QStringLiteral("routines"), routines);
    schema.insert(QStringLiteral("fks"), fks);
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
