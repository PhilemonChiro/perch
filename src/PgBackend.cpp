#include "PgBackend.h"

#include <QObject>
#include <QString>
#include <QVariantMap>

namespace {

// Routes NOTICE/WARNING (RAISE NOTICE, etc.) to the backend's message list
// while a batch runs. libpq calls this synchronously inside PQgetResult on the
// worker thread.
void onNotice(void* arg, const PGresult* res)
{
    auto* b = static_cast<PgBackend*>(arg);
    if (!b || !b->m_msgs || !res)
        return;
    const char* sev = PQresultErrorField(res, PG_DIAG_SEVERITY);
    const char* msg = PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY);
    if (!msg)
        return;
    QString text = QString::fromUtf8(msg);
    if (sev && qstrcmp(sev, "NOTICE") != 0 && qstrcmp(sev, "INFO") != 0)
        text = QString::fromUtf8(sev) + QStringLiteral(": ") + text;
    b->m_msgs->append({ SqlMessage::Info, text, 0 });
}

} // namespace

PgBackend::~PgBackend()
{
    close();
}

void PgBackend::close()
{
    {
        QMutexLocker lock(&m_cancelLock);
        if (m_cancel) {
            PQfreeCancel(m_cancel);
            m_cancel = nullptr;
        }
    }
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
    PQsetNoticeReceiver(m_conn, onNotice, this);
    {
        QMutexLocker lock(&m_cancelLock);
        m_cancel = PQgetCancel(m_conn);
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

void PgBackend::interrupt()
{
    QMutexLocker lock(&m_cancelLock);
    if (m_cancel) {
        char errbuf[256];
        PQcancel(m_cancel, errbuf, sizeof errbuf);
    }
}

bool PgBackend::rows(const QString& sql, QVector<QStringList>& out)
{
    out.clear();
    if (!m_conn)
        return false;
    PGresult* res = PQexec(m_conn, sql.toUtf8().constData());
    const bool ok = res && PQresultStatus(res) == PGRES_TUPLES_OK;
    if (ok) {
        const int n = PQntuples(res), nc = PQnfields(res);
        out.reserve(n);
        for (int r = 0; r < n; ++r) {
            QStringList row;
            for (int c = 0; c < nc; ++c)
                row << QString::fromUtf8(PQgetvalue(res, r, c));
            out << row;
        }
    }
    if (res)
        PQclear(res);
    return ok;
}

bool PgBackend::inTransaction()
{
    if (!m_conn)
        return false;
    const PGTransactionStatusType t = PQtransactionStatus(m_conn);
    return t == PQTRANS_INTRANS || t == PQTRANS_INERROR;
}

QStringList PgBackend::primaryKey(const QString& table, QStringList* types)
{
    QStringList out;
    QString esc = table;
    esc.replace(QLatin1Char('\''), QStringLiteral("''"));
    // The primary key if there is one, else the oldest valid unique index with
    // no predicate or expressions; key columns only (not INCLUDEs), in order.
    const QString q = QStringLiteral(
        "SELECT a.attname, format_type(a.atttypid, NULL) "
        "FROM pg_index i "
        "CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) "
        "JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum "
        "WHERE k.ord <= i.indnkeyatts AND i.indexrelid = ("
        "  SELECT x.indexrelid FROM pg_index x "
        "  WHERE x.indrelid = to_regclass('%1') AND x.indisvalid "
        "    AND (x.indisprimary OR (x.indisunique AND x.indpred IS NULL AND x.indexprs IS NULL)) "
        "  ORDER BY x.indisprimary DESC, x.indexrelid LIMIT 1) "
        "ORDER BY k.ord").arg(esc);
    QVector<QStringList> r;
    if (rows(q, r))
        for (const QStringList& row : std::as_const(r))
            if (row.size() >= 2) {
                out << row.at(0);
                if (types)
                    *types << row.at(1).toLower();
            }
    return out;
}

void PgBackend::schema(QVariantMap& schema)
{
    schema.clear();
    if (!m_conn)
        return;
    QVector<QStringList> r;

    // Tables/views/matviews with typed columns, in column order.
    QVariantMap tables;
    if (rows(QStringLiteral(
                 "SELECT n.nspname || '.' || c.relname, "
                 "       CASE WHEN c.relkind IN ('v', 'm') THEN 'view' ELSE 'table' END, "
                 "       a.attname, format_type(a.atttypid, a.atttypmod) "
                 "FROM pg_attribute a "
                 "JOIN pg_class c ON c.oid = a.attrelid "
                 "JOIN pg_namespace n ON n.oid = c.relnamespace "
                 "WHERE a.attnum > 0 AND NOT a.attisdropped "
                 "  AND c.relkind IN ('r', 'p', 'v', 'm') "
                 "  AND n.nspname NOT IN ('pg_catalog', 'information_schema') "
                 "  AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%' "
                 "ORDER BY c.oid, a.attnum"), r)) {
        for (const QStringList& row : std::as_const(r)) {
            if (row.size() < 4)
                continue;
            QVariantMap t = tables.value(row.at(0)).toMap();
            QVariantList list = t.value(QStringLiteral("columns")).toList();
            list.append(QVariantMap{ { QStringLiteral("name"), row.at(2) }, { QStringLiteral("type"), row.at(3) } });
            t.insert(QStringLiteral("type"), row.at(1));
            t.insert(QStringLiteral("columns"), list);
            tables.insert(row.at(0), t);
        }
    }

    // Functions/procedures with their parameters. Names, modes and types come
    // back as '|'-joined arrays (proallargtypes covers OUT params; when it is
    // NULL every argument is IN and proargtypes lists them). Overloads collapse
    // to the last one read.
    QVariantMap routines;
    if (rows(QStringLiteral(
                 "SELECT n.nspname || '.' || p.proname, "
                 "       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END, "
                 "       COALESCE(array_to_string(p.proargnames, '|', ''), ''), "
                 "       COALESCE(array_to_string(p.proargmodes, '|'), ''), "
                 "       COALESCE((SELECT string_agg(format_type(t, NULL), '|' ORDER BY o) "
                 "                 FROM unnest(COALESCE(p.proallargtypes, p.proargtypes::oid[])) "
                 "                      WITH ORDINALITY AS u(t, o)), '') "
                 "FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                 "WHERE p.prokind IN ('f', 'p') "
                 "  AND n.nspname NOT IN ('pg_catalog', 'information_schema')"), r)) {
        for (const QStringList& row : std::as_const(r)) {
            if (row.size() < 5)
                continue;
            const QStringList names = row.at(2).isEmpty() ? QStringList() : row.at(2).split(QLatin1Char('|'));
            const QStringList modes = row.at(3).isEmpty() ? QStringList() : row.at(3).split(QLatin1Char('|'));
            const QStringList typesL = row.at(4).isEmpty() ? QStringList() : row.at(4).split(QLatin1Char('|'));
            QVariantList params;
            for (int i = 0; i < typesL.size(); ++i) {
                const QString m = i < modes.size() ? modes.at(i) : QStringLiteral("i");
                if (m == QLatin1String("t"))
                    continue; // RETURNS TABLE column, not an argument
                params.append(QVariantMap{
                    { QStringLiteral("name"), i < names.size() ? names.at(i) : QString() },
                    { QStringLiteral("type"), typesL.at(i) },
                    { QStringLiteral("dir"), m == QLatin1String("o") ? QStringLiteral("out")
                                             : m == QLatin1String("b") ? QStringLiteral("inout")
                                                                       : QStringLiteral("in") } });
            }
            routines.insert(row.at(0), QVariantMap{ { QStringLiteral("type"), row.at(1) },
                                                    { QStringLiteral("params"), params } });
        }
    }

    // Foreign keys, one entry per constraint with its column pairs in order.
    QVariantList fks;
    if (rows(QStringLiteral(
                 "SELECT con.oid::text, sn.nspname || '.' || sc.relname, sa.attname, "
                 "       tn.nspname || '.' || tc.relname, ta.attname "
                 "FROM pg_constraint con "
                 "JOIN pg_class sc ON sc.oid = con.conrelid "
                 "JOIN pg_namespace sn ON sn.oid = sc.relnamespace "
                 "JOIN pg_class tc ON tc.oid = con.confrelid "
                 "JOIN pg_namespace tn ON tn.oid = tc.relnamespace "
                 "CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(sk, tk, ord) "
                 "JOIN pg_attribute sa ON sa.attrelid = con.conrelid AND sa.attnum = k.sk "
                 "JOIN pg_attribute ta ON ta.attrelid = con.confrelid AND ta.attnum = k.tk "
                 "WHERE con.contype = 'f' AND sn.nspname NOT IN ('pg_catalog', 'information_schema') "
                 "ORDER BY con.oid, k.ord"), r)) {
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
        for (const QStringList& row : std::as_const(r)) {
            if (row.size() < 5)
                continue;
            if (row.at(0) != lastId) {
                flush();
                lastId = row.at(0);
                cur = QVariantMap{ { QStringLiteral("from"), row.at(1) }, { QStringLiteral("to"), row.at(3) } };
                fromCols.clear();
                toCols.clear();
            }
            fromCols << row.at(2);
            toCols << row.at(4);
        }
        flush();
    }

    schema.insert(QStringLiteral("tables"), tables);
    schema.insert(QStringLiteral("routines"), routines);
    schema.insert(QStringLiteral("fks"), fks);
}

bool PgBackend::runBatch(const QString& sql, QVector<SqlResultSet>& sets,
                         QVector<SqlMessage>& messages, QString& err)
{
    if (!m_conn) {
        err = QStringLiteral("Not connected.");
        return false;
    }
    if (!PQsendQuery(m_conn, sql.toUtf8().constData())) {
        err = QString::fromUtf8(PQerrorMessage(m_conn)).trimmed();
        return false;
    }
    m_msgs = &messages;

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
            messages.append({ SqlMessage::RowCount, QObject::tr("(%n row(s))", nullptr, nrows), 0 });
            sets << set;
        } else if (st == PGRES_COMMAND_OK) {
            // A non-row statement (INSERT/UPDATE/DDL): carry the affected count.
            SqlResultSet set;
            const QByteArray tuples = PQcmdTuples(res);
            set.affected = tuples.isEmpty() ? -1 : tuples.toInt();
            messages.append(set.affected >= 0
                                ? SqlMessage{ SqlMessage::RowCount,
                                              QObject::tr("(%n row(s) affected)", nullptr, set.affected), 0 }
                                : SqlMessage{ SqlMessage::Info, QString::fromUtf8(PQcmdStatus(res)), 0 });
            sets << set;
        } else if (st == PGRES_FATAL_ERROR || st == PGRES_NONFATAL_ERROR) {
            err = QString::fromUtf8(PQresultErrorMessage(res)).trimmed();
            // The server gives a 1-based character offset into the batch; turn
            // it into a line number.
            int line = 0;
            if (const char* pos = PQresultErrorField(res, PG_DIAG_STATEMENT_POSITION)) {
                const int at = QByteArray(pos).toInt();
                if (at > 0)
                    line = int(sql.left(at - 1).count(QLatin1Char('\n'))) + 1;
            }
            const char* primary = PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY);
            if (!cancelRequested())
                messages.append({ SqlMessage::Error,
                                  primary ? QString::fromUtf8(primary) : err, line });
            PQclear(res);
            // Drain any remaining results so the connection stays usable.
            while ((res = PQgetResult(m_conn)) != nullptr)
                PQclear(res);
            m_msgs = nullptr;
            return false;
        }
        PQclear(res);
    }
    m_msgs = nullptr;
    return true;
}
