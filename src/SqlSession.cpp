#include "SqlSession.h"

#include "PgBackend.h"
#include "TdsBackend.h"

#include <QElapsedTimer>
#include <QMetaType>
#include <QObject>
#include <QRegularExpression>

#include <memory>

// The worker lives on its own QThread; all backend (db-lib / libpq) calls happen
// here. It owns the engine backend and marshals the GUI thread's requests to it.
class SqlWorker : public QObject
{
    Q_OBJECT
public:
    explicit SqlWorker(const QString& engine)
    {
        if (engine == QLatin1String("postgres"))
            m_backend = std::make_unique<PgBackend>();
        else
            m_backend = std::make_unique<TdsBackend>();
    }

public slots:
    void connectTo(const QString& host, int port, const QString& user,
                   const QString& password, const QString& database)
    {
        SqlConnectInfo info;
        const QString err = m_backend->open(host, port, user, password, database, info);
        if (!err.isEmpty()) {
            emit failed(err);
            return;
        }
        emit connected(info.databases, info.currentDb, info.tables);
    }

    void switchTo(const QString& name)
    {
        QString currentDb;
        QStringList tables;
        m_backend->switchDatabase(name, currentDb, tables);
        emit switched(currentDb, tables);
    }

    void run(const QString& sql)
    {
        QElapsedTimer timer;
        timer.start();
        QVector<SqlResultSet> sets;
        QString err;
        const bool ok = m_backend->runBatch(sql, sets, err);
        emit results(sets, timer.elapsed(),
                     ok ? QString()
                        : (err.isEmpty() ? QStringLiteral("Query failed.") : err.trimmed()));
    }

    // Fetches fast metadata stats (no table scan) for one table on this same
    // worker thread, after the result grid is already shown.
    void statsFor(const QString& table)
    {
        qint64 rowCount = -1, sizeKb = -1;
        m_backend->stats(table, rowCount, sizeKb);
        emit statsReady(table, rowCount, sizeKb);
    }

    void shutdown() { m_backend->close(); }

signals:
    void connected(const QStringList& databases, const QString& currentDb, const QStringList& tables);
    void switched(const QString& currentDb, const QStringList& tables);
    void failed(const QString& error);
    void results(const QVector<SqlResultSet>& sets, qint64 elapsedMs, const QString& error);
    void statsReady(const QString& table, qint64 rowCount, qint64 sizeKb);

private:
    std::unique_ptr<SqlBackend> m_backend;
};

// ---- SqlSession (GUI thread) ----

SqlSession::SqlSession(const QString& hostId, const QString& host, int port,
                       const QString& username, const QString& database,
                       const QString& engine, QObject* parent)
    : QObject(parent)
    , m_hostId(hostId)
    , m_title(host)
    , m_host(host)
    , m_port(port)
    , m_username(username)
    , m_database(database)
    , m_engine(engine == QLatin1String("postgres") ? QStringLiteral("postgres")
                                                    : QStringLiteral("mssql"))
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

    m_worker = new SqlWorker(m_engine);
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
