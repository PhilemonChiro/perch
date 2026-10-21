#include "PgBackend.h"

#include <QString>
#include <QVariantMap>

PgBackend::~PgBackend()
{
    close();
}

void PgBackend::close()
{
    if (m_conn) {
        PQfinish(m_conn);
        m_conn = nullptr;
    }
}

QString PgBackend::open(const QString& host, int port, const QString& user,
                        const QString& password, const QString& database,
                        SqlConnectInfo& info)
{
    m_host = host;
    m_port = port > 0 ? port : 5432;
    m_user = user;
    m_password = password;
    // libpq connects to a specific database; default to the always-present
    // "postgres" maintenance DB when none was named.
    return doOpen(database.isEmpty() ? QStringLiteral("postgres") : database, info);
}

QString PgBackend::doOpen(const QString& database, SqlConnectInfo& info)
{
    close();

    const QByteArray bHost = m_host.toUtf8();
    const QByteArray bPort = QByteArray::number(m_port);
    const QByteArray bDb = database.toUtf8();
    const QByteArray bUser = m_user.toUtf8();
    const QByteArray bPwd = m_password.toUtf8();

    const char* keywords[] = { "host", "port", "dbname", "user", "password",
                               "connect_timeout", "application_name", nullptr };
    const char* values[] = { bHost.constData(), bPort.constData(), bDb.constData(),
                             bUser.constData(), bPwd.constData(), "8", "Perch", nullptr };

    m_conn = PQconnectdbParams(keywords, values, 0);
    if (!m_conn)
        return QStringLiteral("Could not allocate a connection.");
    if (PQstatus(m_conn) != CONNECTION_OK) {
        QString err = QString::fromUtf8(PQerrorMessage(m_conn)).trimmed();
        close();
        return err.isEmpty() ? QStringLiteral("Could not connect to %1.").arg(m_host) : err;
    }

    info.databases = databaseList();
    info.currentDb = currentDb();
    info.objects = objectList();
    return {};
}

void PgBackend::switchDatabase(const QString& name, QString& currentDb, QVariantList& objects)
{
    SqlConnectInfo info;
    const QString err = doOpen(name, info);
    if (err.isEmpty()) {
        currentDb = info.currentDb;
        objects = info.objects;
    }
}

void PgBackend::stats(const QString& table, qint64& rowCount, qint64& sizeKb)
{
    rowCount = -1;
    sizeKb = -1;
    if (!m_conn)
        return;
    QString esc = table;
    esc.replace(QLatin1Char('\''), QStringLiteral("''"));
    const QString q = QStringLiteral(
        "SELECT c.reltuples::bigint, (pg_total_relation_size(c.oid) / 1024)::bigint "
        "FROM pg_class c WHERE c.oid = to_regclass('%1')").arg(esc);
    PGresult* res = PQexec(m_conn, q.toUtf8().constData());
    if (res && PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) >= 1
        && PQnfields(res) >= 2) {
        bool ok1 = false, ok2 = false;
        const qint64 rc = QString::fromUtf8(PQgetvalue(res, 0, 0)).toLongLong(&ok1);
        const qint64 kb = QString::fromUtf8(PQgetvalue(res, 0, 1)).toLongLong(&ok2);
        // reltuples is -1 on a table never analysed; treat that as "unknown".
        rowCount = (ok1 && rc >= 0) ? rc : -1;
        sizeKb = ok2 ? kb : -1;
    }
    if (res)
        PQclear(res);
}

QStringList PgBackend::firstColumn(const QString& sql)
{
    QStringList out;
    if (!m_conn)
        return out;
    PGresult* res = PQexec(m_conn, sql.toUtf8().constData());
    if (res && PQresultStatus(res) == PGRES_TUPLES_OK) {
        const int n = PQntuples(res);
        for (int r = 0; r < n; ++r)
            if (!PQgetisnull(res, r, 0))
                out << QString::fromUtf8(PQgetvalue(res, r, 0));
    }
    if (res)
        PQclear(res);
    return out;
}

QStringList PgBackend::databaseList()
{
    return firstColumn(QStringLiteral(
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn "
        "ORDER BY datname"));
}

QString PgBackend::currentDb()
{
    const QStringList r = firstColumn(QStringLiteral("SELECT current_database()"));
    return r.isEmpty() ? QString() : r.first();
}

// Every browsable object — tables, views, procedures and functions — each as
// {"name": "schema.name", "type": ...}, ordered by type then name.
QVariantList PgBackend::objectList()
{
    QVariantList out;
    if (!m_conn)
        return out;
    // Read the catalog tables directly rather than information_schema, whose
    // views (routines especially) join many tables and are markedly slower on a
    // database with many objects.
    const QString sql = QStringLiteral(
        "SELECT name, typ, args FROM ("
        "  SELECT n.nspname || '.' || c.relname AS name, "
        "         CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'view' ELSE 'table' END AS typ, "
        "         '' AS args, "
        "         CASE c.relkind WHEN 'v' THEN 1 WHEN 'm' THEN 1 ELSE 0 END AS ord "
        "  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "  WHERE c.relkind IN ('r', 'p', 'v', 'm') "
        "    AND n.nspname NOT IN ('pg_catalog', 'information_schema') "
        "    AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%' "
        "  UNION ALL "
        "  SELECT n.nspname || '.' || p.proname, "
        "         CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END, "
        "         pg_get_function_arguments(p.oid), "
        "         CASE p.prokind WHEN 'p' THEN 2 ELSE 3 END "
        "  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "  WHERE p.prokind IN ('f', 'p') "
        "    AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        ") q ORDER BY ord, name");
    PGresult* res = PQexec(m_conn, sql.toUtf8().constData());
    if (res && PQresultStatus(res) == PGRES_TUPLES_OK) {
        const int n = PQntuples(res);
        for (int r = 0; r < n; ++r)
            if (!PQgetisnull(res, r, 0))
                out.append(QVariantMap{
                    { QStringLiteral("name"), QString::fromUtf8(PQgetvalue(res, r, 0)) },
                    { QStringLiteral("type"), QString::fromUtf8(PQgetvalue(res, r, 1)) },
                    { QStringLiteral("args"), QString::fromUtf8(PQgetvalue(res, r, 2)) } });
    }
    if (res)
        PQclear(res);
    return out;
}

// Column names for every table/view/matview, grouped by "schema.name", for
// editor autocompletion. Read straight from pg_attribute, in column order.
QVariantMap PgBackend::columnList()
{
    QVariantMap out;
    if (!m_conn)
        return out;
    const QString sql = QStringLiteral(
        "SELECT n.nspname || '.' || c.relname AS tbl, a.attname "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE a.attnum > 0 AND NOT a.attisdropped "
        "  AND c.relkind IN ('r', 'p', 'v', 'm') "
        "  AND n.nspname NOT IN ('pg_catalog', 'information_schema') "
        "  AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%' "
        "ORDER BY c.oid, a.attnum");
    PGresult* res = PQexec(m_conn, sql.toUtf8().constData());
    if (res && PQresultStatus(res) == PGRES_TUPLES_OK) {
        const int n = PQntuples(res);
        for (int r = 0; r < n; ++r) {
            if (PQgetisnull(res, r, 0))
                continue;
            const QString tbl = QString::fromUtf8(PQgetvalue(res, r, 0));
            QVariantList cur = out.value(tbl).toList();
            cur.append(QString::fromUtf8(PQgetvalue(res, r, 1)));
            out.insert(tbl, cur);
        }
    }
    if (res)
        PQclear(res);
    return out;
}

bool PgBackend::runBatch(const QString& sql, QVector<SqlResultSet>& sets, QString& err)
{
    if (!m_conn) {
        err = QStringLiteral("Not connected.");
        return false;
    }
    if (!PQsendQuery(m_conn, sql.toUtf8().constData())) {
        err = QString::fromUtf8(PQerrorMessage(m_conn)).trimmed();
        return false;
    }

    // The simple-query protocol returns one result per statement in the batch.
    PGresult* res = nullptr;
    while ((res = PQgetResult(m_conn)) != nullptr) {
        const ExecStatusType st = PQresultStatus(res);
        if (st == PGRES_TUPLES_OK || st == PGRES_SINGLE_TUPLE) {
            SqlResultSet set;
            const int ncols = PQnfields(res);
            for (int c = 0; c < ncols; ++c)
                set.columns << QString::fromUtf8(PQfname(res, c));
            const int nrows = PQntuples(res);
            for (int r = 0; r < nrows; ++r) {
                QStringList row;
                row.reserve(ncols);
                for (int c = 0; c < ncols; ++c)
                    row << (PQgetisnull(res, r, c) ? QString()
                                                   : QString::fromUtf8(PQgetvalue(res, r, c)));
                set.rows << row;
            }
            sets << set;
        } else if (st == PGRES_COMMAND_OK) {
            // A non-row statement (INSERT/UPDATE/DDL): carry the affected count.
            SqlResultSet set;
            const QByteArray tuples = PQcmdTuples(res);
            set.affected = tuples.isEmpty() ? -1 : tuples.toInt();
            sets << set;
        } else if (st == PGRES_FATAL_ERROR || st == PGRES_NONFATAL_ERROR) {
            err = QString::fromUtf8(PQresultErrorMessage(res)).trimmed();
            PQclear(res);
            // Drain any remaining results so the connection stays usable.
            while ((res = PQgetResult(m_conn)) != nullptr)
                PQclear(res);
            return false;
        }
        PQclear(res);
    }
    return true;
}
