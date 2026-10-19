#include "PgBackend.h"

#include <QString>

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
    info.tables = tableList();
    return {};
}

void PgBackend::switchDatabase(const QString& name, QString& currentDb, QStringList& tables)
{
    SqlConnectInfo info;
    const QString err = doOpen(name, info);
    if (err.isEmpty()) {
        currentDb = info.currentDb;
        tables = info.tables;
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

QStringList PgBackend::tableList()
{
    return firstColumn(QStringLiteral(
        "SELECT table_schema || '.' || table_name FROM information_schema.tables "
        "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
        "AND table_type IN ('BASE TABLE', 'VIEW') ORDER BY table_schema, table_name"));
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
