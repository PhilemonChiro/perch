#include "SqlSession.h"

#include "PgBackend.h"
#include "TdsBackend.h"

#include <QElapsedTimer>
#include <QMetaType>
#include <QObject>
#include <QRegularExpression>
#include <QVariantMap>

#include <memory>

namespace {

// One GO-separated batch of a SQL Server script: its text, how many times to
// run it ("GO n"), and the 0-based line of the script it starts on.
struct GoBatch
{
    QString sql;
    int repeat = 1;
    int line = 0;
};

// Splits a script on lines holding only "GO" or "GO n" (an optional trailing
// -- comment allowed), ignoring any inside strings, [identifiers], "quoted
// identifiers" and comments (block comments nest in T-SQL). Blank batches are
// dropped.
QVector<GoBatch> splitGoBatches(const QString& sql)
{
    static const QRegularExpression goLine(
        QStringLiteral("^[ \\t]*go(?:[ \\t]+(\\d+))?[ \\t\\r]*(?:--.*)?$"),
        QRegularExpression::CaseInsensitiveOption);
    enum State { Code, Str, Quoted, Bracket, LineComment, BlockComment };
    QVector<GoBatch> out;
    const int n = int(sql.size());
    int batchStart = 0, batchLine = 0, line = 0, depth = 0;
    State st = Code;
    bool lineStart = true;
    const auto push = [&](int end, int repeat) {
        const QString text = sql.mid(batchStart, end - batchStart);
        if (!text.trimmed().isEmpty())
            out.append({ text, std::max(1, repeat), batchLine });
    };
    int i = 0;
    while (i < n) {
        if (lineStart && st == Code) {
            int eol = int(sql.indexOf(QLatin1Char('\n'), i));
            if (eol < 0)
                eol = n;
            const auto m = goLine.matchView(QStringView(sql).mid(i, eol - i));
            if (m.hasMatch()) {
                push(i, m.captured(1).isEmpty() ? 1 : m.captured(1).toInt());
                i = eol < n ? eol + 1 : n;
                ++line;
                batchStart = i;
                batchLine = line;
                continue;
            }
        }
        lineStart = false;
        const QChar c = sql.at(i);
        const QChar c2 = i + 1 < n ? sql.at(i + 1) : QChar();
        switch (st) {
        case Code:
            if (c == QLatin1Char('\'')) st = Str;
            else if (c == QLatin1Char('"')) st = Quoted;
            else if (c == QLatin1Char('[')) st = Bracket;
            else if (c == QLatin1Char('-') && c2 == QLatin1Char('-')) { st = LineComment; ++i; }
            else if (c == QLatin1Char('/') && c2 == QLatin1Char('*')) { st = BlockComment; depth = 1; ++i; }
            break;
        case Str:
            if (c == QLatin1Char('\'')) { if (c2 == QLatin1Char('\'')) ++i; else st = Code; }
            break;
        case Quoted:
            if (c == QLatin1Char('"')) { if (c2 == QLatin1Char('"')) ++i; else st = Code; }
            break;
        case Bracket:
            if (c == QLatin1Char(']')) { if (c2 == QLatin1Char(']')) ++i; else st = Code; }
            break;
        case LineComment:
            if (c == QLatin1Char('\n')) st = Code;
            break;
        case BlockComment:
            if (c == QLatin1Char('/') && c2 == QLatin1Char('*')) { ++depth; ++i; }
            else if (c == QLatin1Char('*') && c2 == QLatin1Char('/')) { if (--depth == 0) st = Code; ++i; }
            break;
        }
        if (i < n && sql.at(i) == QLatin1Char('\n')) {
            ++line;
            lineStart = true;
        }
        ++i;
    }
    push(n, 1);
    return out;
}

// Splits "db.schema.table" on dots outside [..] / ".." quoting; each part is
// returned unquoted with whether it was quoted.
QVector<QPair<QString, bool>> identParts(const QString& name)
{
    QVector<QPair<QString, bool>> parts;
    QString cur;
    bool quoted = false;
    QChar close;
    for (int i = 0; i < name.size(); ++i) {
        const QChar c = name.at(i);
        if (!close.isNull()) {
            if (c == close) {
                if (i + 1 < name.size() && name.at(i + 1) == close) { cur += c; ++i; }
                else close = QChar();
            } else {
                cur += c;
            }
        } else if (c == QLatin1Char('[')) { close = QLatin1Char(']'); quoted = true; }
        else if (c == QLatin1Char('"')) { close = QLatin1Char('"'); quoted = true; }
        else if (c == QLatin1Char('.')) { parts.append({ cur.trimmed(), quoted }); cur.clear(); quoted = false; }
        else cur += c;
    }
    parts.append({ cur.trimmed(), quoted });
    return parts;
}

} // namespace

// The worker lives on its own QThread; all backend (db-lib / libpq) calls happen
// here. It owns the engine backend and marshals the GUI thread's requests to it.
class SqlWorker : public QObject
{
    Q_OBJECT
public:
    explicit SqlWorker(const QString& engine)
        : m_pg(engine == QLatin1String("postgres"))
    {
        if (m_pg)
            m_backend = std::make_unique<PgBackend>();
        else
            m_backend = std::make_unique<TdsBackend>();
    }

    // Called directly from the GUI thread (not queued): the backend's cancel
    // members are the thread-safe ones.
    void cancelNow() { m_backend->requestCancel(); }
    void clearCancel() { m_backend->clearCancel(); }

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
        emit connected(info.databases, info.currentDb, info.objects);
    }

    void switchTo(const QString& name)
    {
        QString currentDb;
        QVariantList objects;
        m_backend->switchDatabase(name, currentDb, objects);
        emit switched(currentDb, objects);
    }

    // Runs a script: SQL Server scripts batch by batch on GO lines (GO n
    // repeats), PostgreSQL as one batch. Server line numbers (relative to a
    // batch) are shifted to editor lines. With `stopOnError` off, later
    // batches still run after one fails, each error reported.
    void run(const QString& sql, bool stopOnError, int lineBase)
    {
        // The connection dropped while idle: nothing has run yet, so reconnect
        // and run the script again from the top.
        if (m_backend->isDead()) {
            m_backend->close();
            emit connectionLost(sql, lineBase, true);
            return;
        }
        QElapsedTimer timer;
        timer.start();
        QVector<SqlResultSet> sets;
        QVector<SqlMessage> messages;
        QStringList errors;
        bool cancelled = false;
        const QVector<GoBatch> batches = m_pg ? QVector<GoBatch>{ { sql, 1, 0 } } : splitGoBatches(sql);
        for (const GoBatch& b : batches) {
            for (int k = 0; k < b.repeat && !cancelled; ++k) {
                if (m_backend->cancelRequested()) {
                    cancelled = true;
                    break;
                }
                QVector<SqlMessage> batchMsgs;
                QString err;
                const bool ok = m_backend->runBatch(b.sql, sets, batchMsgs, err);
                bool sawError = false;
                for (SqlMessage& m : batchMsgs) {
                    if (m.line > 0)
                        m.line += b.line + lineBase;
                    sawError = sawError || m.kind == SqlMessage::Error;
                }
                messages += batchMsgs;
                if (ok)
                    continue;
                if (m_backend->cancelRequested()) {
                    cancelled = true;
                    break;
                }
                const QString e = err.isEmpty() ? QStringLiteral("Query failed.") : err.trimmed();
                if (!sawError)
                    messages.append({ SqlMessage::Error, e, 0 });
                errors << (batches.size() > 1 ? QStringLiteral("Batch at line %1: %2")
                                                    .arg(b.line + lineBase + 1).arg(e)
                                              : e);
                if (stopOnError)
                    break;
            }
            if (cancelled || (stopOnError && !errors.isEmpty()))
                break;
        }
        if (cancelled)
            messages.append({ SqlMessage::Info, QStringLiteral("Query cancelled."), 0 });
        // Re-arm so metadata queries after a cancel are not interrupted too.
        m_backend->clearCancel();
        // Dropped mid-run: part of the script may have run, so never re-run it;
        // report what happened and reconnect for the next query.
        const bool dead = m_backend->isDead();
        if (dead) {
            m_backend->close();
            messages.append({ SqlMessage::Error,
                              QStringLiteral("Connection lost during the query; reconnecting. "
                                             "Statements before the failure may have run."), 0 });
        }
        emit results(sets, messages, timer.elapsed(), errors.join(QLatin1Char('\n')), cancelled);
        if (dead)
            emit connectionLost(QString(), 0, false);
    }

    // See SqlSession::deleteRows().
    void deleteRows(const QString& table, const QStringList& columns, const QVariantList& rows, bool dryRun)
    {
        const auto done = [&](int n, const QString& err, const QString& sql = {}) {
            emit rowsDeleted(n, err, sql, dryRun);
        };
        if (!m_backend->isOpen())
            return done(0, QStringLiteral("Not connected. Run a query to resume, then try again."));
        if (rows.isEmpty())
            return done(0, QStringLiteral("No rows selected."));

        QStringList types;
        const QStringList keys = m_backend->primaryKey(table, &types);
        if (keys.isEmpty())
            return done(0, QStringLiteral("%1 has no primary key or unique index, so its rows can't be "
                                          "identified safely.").arg(table));
        QVector<int> keyIdx;
        QStringList missing;
        for (const QString& k : keys) {
            int at = int(columns.indexOf(k));
            if (at < 0 && !m_pg)
                for (int c = 0; c < columns.size() && at < 0; ++c)
                    if (columns.at(c).compare(k, Qt::CaseInsensitive) == 0)
                        at = c;
            if (at < 0)
                missing << k;
            keyIdx << at;
        }
        if (!missing.isEmpty())
            return done(0, QStringLiteral("The result doesn't include the key column%1 %2 of %3. "
                                          "Add %4 to the SELECT to delete rows.")
                               .arg(missing.size() > 1 ? QStringLiteral("s") : QString(),
                                    missing.join(QStringLiteral(", ")), table,
                                    missing.size() > 1 ? QStringLiteral("them") : QStringLiteral("it")));

        const auto quoteIdent = [&](const QString& part) {
            if (m_pg) {
                QString p = part;
                return QLatin1Char('"') + p.replace(QLatin1Char('"'), QStringLiteral("\"\"")) + QLatin1Char('"');
            }
            QString p = part;
            return QLatin1Char('[') + p.replace(QLatin1Char(']'), QStringLiteral("]]")) + QLatin1Char(']');
        };
        // PostgreSQL folds unquoted identifiers to lower case; keep that meaning.
        QStringList qparts;
        for (const auto& part : identParts(table))
            qparts << quoteIdent((m_pg && !part.second) ? part.first.toLower() : part.first);
        const QString target = qparts.join(QLatin1Char('.'));

        static const QRegularExpression numRe(QStringLiteral("^[+-]?\\d+(\\.\\d+)?([eE][+-]?\\d+)?$"));
        static const QStringList numericTypes = {
            QStringLiteral("int"), QStringLiteral("bigint"), QStringLiteral("smallint"),
            QStringLiteral("tinyint"), QStringLiteral("decimal"), QStringLiteral("numeric"),
            QStringLiteral("float"), QStringLiteral("real"), QStringLiteral("money"),
            QStringLiteral("smallmoney"), QStringLiteral("bit"), QStringLiteral("integer"),
            QStringLiteral("double precision"), QStringLiteral("oid")
        };
        const auto literal = [&](const QString& v, const QString& type) {
            if (numericTypes.contains(type) && numRe.match(v).hasMatch())
                return v;
            QString e = v;
            e.replace(QLatin1Char('\''), QStringLiteral("''"));
            const bool unicode = !m_pg && (type == QLatin1String("nvarchar") || type == QLatin1String("nchar")
                                           || type == QLatin1String("ntext"));
            return (unicode ? QStringLiteral("N'") : QStringLiteral("'")) + e + QLatin1Char('\'');
        };

        // One predicate per row (key = value, NULL as IS NULL); a single-column
        // key without NULLs uses IN. Chunked so no statement grows unbounded.
        QStringList statements;
        constexpr int kChunk = 500;
        for (int from = 0; from < rows.size(); from += kChunk) {
            const int to = std::min(int(rows.size()), from + kChunk);
            QStringList preds, inList;
            bool simple = keys.size() == 1;
            for (int r = from; r < to; ++r) {
                const QVariantList vals = rows.at(r).toList();
                QStringList conj;
                for (int k = 0; k < keys.size(); ++k) {
                    const QVariant v = keyIdx.at(k) < vals.size() ? vals.at(keyIdx.at(k)) : QVariant();
                    if (v.isNull()) {
                        conj << quoteIdent(keys.at(k)) + QStringLiteral(" IS NULL");
                        simple = false;
                    } else {
                        const QString lit = literal(v.toString(), types.value(k));
                        conj << quoteIdent(keys.at(k)) + QStringLiteral(" = ") + lit;
                        inList << lit;
                    }
                }
                preds << (conj.size() > 1 ? QLatin1Char('(') + conj.join(QStringLiteral(" AND ")) + QLatin1Char(')')
                                          : conj.first());
            }
            statements << QStringLiteral("DELETE FROM %1\nWHERE %2")
                              .arg(target, simple ? quoteIdent(keys.first()) + QStringLiteral(" IN (")
                                                        + inList.join(QStringLiteral(", ")) + QLatin1Char(')')
                                                  : preds.join(QStringLiteral("\n   OR ")));
        }
        const QString deletes = statements.join(QStringLiteral(";\n")) + QLatin1Char(';');

        if (dryRun) {
            const QString sql = QStringLiteral(
                "-- Deletes %1 row(s) from %2, keyed on %3.\n%4\n%5\n"
                "-- Check the row count, then run COMMIT instead of ROLLBACK.\n%6\n")
                .arg(rows.size()).arg(table, keys.join(QStringLiteral(", ")),
                     m_pg ? QStringLiteral("BEGIN;") : QStringLiteral("BEGIN TRANSACTION;"), deletes,
                     m_pg ? QStringLiteral("ROLLBACK;") : QStringLiteral("ROLLBACK TRANSACTION;"));
            return done(0, {}, sql);
        }

        // Inside the user's own open transaction, nest a savepoint so a rollback
        // here never discards their work.
        const bool nested = m_backend->inTransaction();
        const QString begin = nested ? (m_pg ? QStringLiteral("SAVEPOINT perch_delete")
                                             : QStringLiteral("SAVE TRANSACTION perch_delete"))
                                     : (m_pg ? QStringLiteral("BEGIN") : QStringLiteral("BEGIN TRANSACTION"));
        const QString rollback = nested ? (m_pg ? QStringLiteral("ROLLBACK TO SAVEPOINT perch_delete")
                                                : QStringLiteral("ROLLBACK TRANSACTION perch_delete"))
                                        : (m_pg ? QStringLiteral("ROLLBACK") : QStringLiteral("ROLLBACK TRANSACTION"));
        const QString commit = nested ? (m_pg ? QStringLiteral("RELEASE SAVEPOINT perch_delete") : QString())
                                      : (m_pg ? QStringLiteral("COMMIT") : QStringLiteral("COMMIT TRANSACTION"));
        const auto exec = [&](const QString& q, int* affected, QString& err) {
            QVector<SqlResultSet> sets;
            QVector<SqlMessage> msgs;
            if (!m_backend->runBatch(q, sets, msgs, err)) {
                if (err.isEmpty())
                    err = QStringLiteral("Statement failed.");
                return false;
            }
            if (affected)
                for (const SqlResultSet& s : sets)
                    if (s.affected > 0)
                        *affected += s.affected;
            return true;
        };
        QString err;
        if (!exec(begin, nullptr, err))
            return done(0, QStringLiteral("Could not start a transaction: %1").arg(err.trimmed()));
        int total = 0;
        for (const QString& st : std::as_const(statements)) {
            if (!exec(st, &total, err)) {
                QString ignored;
                exec(rollback, nullptr, ignored);
                return done(0, QStringLiteral("Delete failed and was rolled back: %1").arg(err.trimmed()), deletes);
            }
        }
        if (total != rows.size()) {
            QString ignored;
            exec(rollback, nullptr, ignored);
            return done(0, QStringLiteral("Expected %1, would delete %2 — rolled back.")
                               .arg(rows.size()).arg(total), deletes);
        }
        if (!commit.isEmpty() && !exec(commit, nullptr, err))
            return done(0, QStringLiteral("Commit failed: %1").arg(err.trimmed()), deletes);
        done(total, {}, deletes);
    }

    // Fetches fast metadata stats (no table scan) for one table on this same
    // worker thread, after the result grid is already shown.
    void statsFor(const QString& table)
    {
        qint64 rowCount = -1, sizeKb = -1;
        m_backend->stats(table, rowCount, sizeKb);
        emit statsReady(table, rowCount, sizeKb);
    }

    // Re-reads the object list for the current database (manual refresh).
    void refresh()
    {
        QVariantList objects;
        m_backend->refreshObjects(objects);
        emit objectsRefreshed(objects);
    }

    // Fetches the IntelliSense schema for the current database. The database
    // name the GUI expected is echoed back so it caches under the right key.
    void loadSchema(const QString& database)
    {
        QVariantMap schema;
        m_backend->schema(schema);
        emit schemaReady(database, schema);
    }

    void setTimeout(int seconds) { m_backend->setQueryTimeout(seconds); }

    void shutdown() { m_backend->close(); }

signals:
    void connected(const QStringList& databases, const QString& currentDb, const QVariantList& objects);
    void switched(const QString& currentDb, const QVariantList& objects);
    void objectsRefreshed(const QVariantList& objects);
    void schemaReady(const QString& database, const QVariantMap& schema);
    void failed(const QString& error);
    // The connection was found dead; `rerun` when `sql` never reached the server.
    void connectionLost(const QString& sql, int lineBase, bool rerun);
    void results(const QVector<SqlResultSet>& sets, const QVector<SqlMessage>& messages,
                 qint64 elapsedMs, const QString& error, bool cancelled);
    void statsReady(const QString& table, qint64 rowCount, qint64 sizeKb);
    void rowsDeleted(int count, const QString& error, const QString& sql, bool dryRun);

private:
    const bool m_pg;
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
    qRegisterMetaType<QVector<SqlMessage>>("QVector<SqlMessage>");

    m_backoffTimer.setSingleShot(true);
    connect(&m_backoffTimer, &QTimer::timeout, this, [this] { attemptConnect(); });
    m_countdownTimer.setInterval(1000);
    connect(&m_countdownTimer, &QTimer::timeout, this, [this] {
        if (m_retrySecondsLeft > 0)
            --m_retrySecondsLeft;
        if (m_retrySecondsLeft <= 0)
            m_countdownTimer.stop();
        emit retryChanged();
    });

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
    connect(this, &SqlSession::doRefreshObjects, m_worker, &SqlWorker::refresh);
    connect(this, &SqlSession::doSchema, m_worker, &SqlWorker::loadSchema);
    connect(this, &SqlSession::doDelete, m_worker, &SqlWorker::deleteRows);
    connect(this, &SqlSession::doQueryTimeout, m_worker, &SqlWorker::setTimeout);
    connect(this, &SqlSession::doStats, m_worker, &SqlWorker::statsFor);
    connect(m_worker, &SqlWorker::connected, this, &SqlSession::onConnected);
    connect(m_worker, &SqlWorker::switched, this, &SqlSession::onSwitched);
    connect(m_worker, &SqlWorker::objectsRefreshed, this, &SqlSession::onObjectsRefreshed);
    connect(m_worker, &SqlWorker::schemaReady, this, &SqlSession::onSchemaReady);
    connect(m_worker, &SqlWorker::rowsDeleted, this, [this](int n, const QString& err, const QString& sql, bool dry) {
        kickIdle();
        emit rowsDeleted(n, err, sql, dry);
    });
    connect(m_worker, &SqlWorker::failed, this, &SqlSession::onFailed);
    connect(m_worker, &SqlWorker::results, this, &SqlSession::onResults);
    connect(m_worker, &SqlWorker::connectionLost, this, &SqlSession::onConnectionLost);
    connect(m_worker, &SqlWorker::statsReady, this, &SqlSession::onStats);
    m_thread.start();
}

SqlSession::~SqlSession()
{
    // Abort a running query first so the blocking shutdown below doesn't wait
    // on it.
    m_worker->cancelNow();
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
    m_errorIsAuth = false;
    emit errorChanged();
    m_retryCount = 0;
    m_backoffTimer.stop();
    m_countdownTimer.stop();
    m_retrySecondsLeft = 0;
    emit retryChanged();
    attemptConnect();
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
    m_errorIsAuth = false;
    emit errorChanged();
    m_retryCount = 0;
    m_backoffTimer.stop();
    m_countdownTimer.stop();
    m_retrySecondsLeft = 0;
    emit retryChanged();
    attemptConnect();
}

// Fires one connect attempt (first try or a backoff retry). The error text is
// left intact so the retry UI can keep showing why the previous try failed.
void SqlSession::attemptConnect()
{
    m_countdownTimer.stop();
    m_retrySecondsLeft = 0;
    ++m_retryCount;
    emit retryChanged();
    m_statusText = m_retryCount <= 1
        ? QStringLiteral("Connecting…")
        : QStringLiteral("Reconnecting… (attempt %1 of %2)").arg(m_retryCount).arg(kMaxRetries);
    emit statusChanged();
    setState(Connecting);
    emit doConnect(m_host, m_port, m_username, m_password, m_currentDatabase);
}

// Waits with exponential backoff (3s, 6s, 12s, 24s, capped at 30s), counting
// down each second, then re-attempts. State stays Connecting throughout.
void SqlSession::scheduleRetry()
{
    int delay = kBackoffBaseMs;
    for (int i = 1; i < m_retryCount; ++i) {
        delay *= 2;
        if (delay >= kBackoffCapMs) { delay = kBackoffCapMs; break; }
    }
    m_retrySecondsLeft = (delay + 999) / 1000;
    m_statusText = QStringLiteral("Connection failed — retrying in %1s… (attempt %2 of %3)")
                       .arg(m_retrySecondsLeft).arg(m_retryCount + 1).arg(kMaxRetries);
    emit statusChanged();
    emit retryChanged();
    m_countdownTimer.start();
    m_backoffTimer.start(delay);
}

void SqlSession::abortConnect()
{
    m_backoffTimer.stop();
    m_countdownTimer.stop();
    m_retrySecondsLeft = 0;
    emit retryChanged();
    if (m_state == Connecting) {
        m_statusText = QStringLiteral("Connection cancelled.");
        emit statusChanged();
        setState(Failed);
    }
}

bool SqlSession::isAuthError(const QString& error)
{
    const QString e = error.toLower();
    static const char* const markers[] = {
        "login failed", "password", "authentication failed", "permission denied",
        "not associated with a trusted", "28p01", "28000", "18456"
    };
    for (const char* m : markers)
        if (e.contains(QLatin1String(m)))
            return true;
    return false;
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

void SqlSession::execute(const QString& sql, int lineBase)
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
        m_pendingLineBase = lineBase;
        reconnect();
        return;
    }
    if (m_state != Connected && m_state != Executing)
        return;
    m_statusText = QStringLiteral("Running…");
    emit statusChanged();
    setState(Executing);
    kickIdle();
    m_worker->clearCancel();
    emit doExecute(sql, m_stopOnError, lineBase);
}

void SqlSession::cancel()
{
    if (m_state != Executing)
        return;
    m_statusText = QStringLiteral("Cancelling…");
    emit statusChanged();
    m_worker->cancelNow();
}

void SqlSession::setQueryTimeout(int seconds)
{
    emit doQueryTimeout(seconds);
}

void SqlSession::setStopOnError(bool on)
{
    if (m_stopOnError == on)
        return;
    m_stopOnError = on;
    emit stopOnErrorChanged();
}

void SqlSession::deleteRows(const QString& table, const QStringList& columns,
                            const QVariantList& rows, bool dryRun)
{
    if (m_state != Connected && m_state != Executing) {
        emit rowsDeleted(0, QStringLiteral("Not connected. Run a query to resume, then try again."),
                         QString(), dryRun);
        return;
    }
    kickIdle();
    emit doDelete(table, columns, rows, dryRun);
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

void SqlSession::refreshObjects()
{
    if (m_state != Connected)
        return;
    kickIdle();
    emit doRefreshObjects();
    requestSchema(true);
}

void SqlSession::requestSchema(bool force)
{
    if (!force && m_schemaCache.contains(m_currentDatabase)) {
        const QVariantMap cached = m_schemaCache.value(m_currentDatabase);
        if (cached != m_schema) {
            m_schema = cached;
            emit schemaChanged();
        }
        return;
    }
    if (m_state != Connected && m_state != Executing)
        return;
    kickIdle();
    emit doSchema(m_currentDatabase);
}

void SqlSession::onSchemaReady(const QString& database, const QVariantMap& schema)
{
    m_schemaCache.insert(database, schema);
    if (database == m_currentDatabase) {
        m_schema = schema;
        emit schemaChanged();
    }
    kickIdle();
}

void SqlSession::disconnectSession()
{
    m_idleTimer.stop();
    QMetaObject::invokeMethod(m_worker, "shutdown", Qt::QueuedConnection);
    m_statusText = QStringLiteral("Disconnected.");
    emit statusChanged();
    setState(Disconnected);
}

// Names of the table/view objects only — used for the sidebar count and any
// consumer that wants a plain selectable-table list.
static QStringList tableNames(const QVariantList& objects)
{
    QStringList out;
    for (const QVariant& v : objects) {
        const QVariantMap m = v.toMap();
        const QString type = m.value(QStringLiteral("type")).toString();
        if (type == QLatin1String("table") || type == QLatin1String("view"))
            out << m.value(QStringLiteral("name")).toString();
    }
    return out;
}

void SqlSession::onConnected(const QStringList& databases, const QString& currentDb,
                             const QVariantList& objects)
{
    m_haveConnected = true;
    m_backoffTimer.stop();
    m_countdownTimer.stop();
    m_retryCount = 0;
    m_retrySecondsLeft = 0;
    emit retryChanged();
    m_databases = databases;
    emit databasesChanged();
    if (!currentDb.isEmpty() && currentDb != m_currentDatabase) {
        m_currentDatabase = currentDb;
        emit currentDatabaseChanged();
    }
    m_objects = objects;
    m_tables = tableNames(objects);
    emit tablesChanged();
    m_statusText = QStringLiteral("Connected.");
    emit statusChanged();
    setState(Connected);
    kickIdle();

    // Prefetch the IntelliSense schema (background; cached per database).
    requestSchema();

    // Persist the password now that we know it works, if asked.
    if (m_remember && !m_hostId.isEmpty() && !m_password.isEmpty())
        emit rememberPassword(m_password);

    if (!m_pendingSql.isEmpty()) {
        const QString sql = m_pendingSql;
        m_pendingSql.clear();
        execute(sql, m_pendingLineBase);
    }
}

void SqlSession::onSwitched(const QString& currentDb, const QVariantList& objects)
{
    if (!currentDb.isEmpty() && currentDb != m_currentDatabase) {
        m_currentDatabase = currentDb;
        emit currentDatabaseChanged();
    }
    m_objects = objects;
    m_tables = tableNames(objects);
    emit tablesChanged();
    requestSchema();   // IntelliSense schema for the new database (cached)
    kickIdle();
}

void SqlSession::onObjectsRefreshed(const QVariantList& objects)
{
    m_objects = objects;
    m_tables = tableNames(objects);
    emit tablesChanged();
    kickIdle();
}

// The server or network dropped the connection. Reconnect with the in-memory
// password; a query that never reached the server runs once the link is back.
void SqlSession::onConnectionLost(const QString& sql, int lineBase, bool rerun)
{
    if (rerun && !sql.isEmpty()) {
        m_pendingSql = sql;
        m_pendingLineBase = lineBase;
    }
    m_statusText = QStringLiteral("Connection lost — reconnecting…");
    emit statusChanged();
    setState(Disconnected);
    reconnect();
}

void SqlSession::onFailed(const QString& error)
{
    m_pendingSql.clear();
    m_errorText = error;
    m_errorIsAuth = isAuthError(error);
    emit errorChanged();

    // Auth failures won't fix themselves — stop and let the UI re-prompt. Other
    // failures (unreachable server, network, timeout) are often transient on the
    // first try, so auto-retry with backoff — unless the attempt was aborted
    // (state no longer Connecting) or we have no password to retry with.
    if (m_state == Connecting && !m_errorIsAuth && !m_password.isEmpty()
        && m_retryCount < kMaxRetries) {
        scheduleRetry();
        return;
    }
    m_backoffTimer.stop();
    m_countdownTimer.stop();
    m_retrySecondsLeft = 0;
    emit retryChanged();
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

QVariantMap SqlSession::snapshotResults() const
{
    QVariantMap out;
    QVariantList models;
    if (!m_sets.isEmpty()) {
        const auto adopt = [&](SqlResultModel* src) {
            SqlResultModel* copy = src->clone(nullptr);
            QQmlEngine::setObjectOwnership(copy, QQmlEngine::JavaScriptOwnership);
            models.append(QVariant::fromValue(static_cast<QObject*>(copy)));
        };
        adopt(m_result);
        for (SqlResultModel* m : m_extraModels)
            adopt(m);
    }
    out.insert(QStringLiteral("models"), models);
    out.insert(QStringLiteral("message"), m_message);
    out.insert(QStringLiteral("error"), m_errorText);
    out.insert(QStringLiteral("statsTable"), m_statsTable);
    out.insert(QStringLiteral("messages"), m_messages);
    out.insert(QStringLiteral("cancelled"), m_cancelled);
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

void SqlSession::onResults(const QVector<SqlResultSet>& sets, const QVector<SqlMessage>& messages,
                           qint64 elapsed, const QString& error, bool cancelled)
{
    m_elapsed = elapsed;
    m_cancelled = cancelled;

    // Split into grid sets (with columns) and a running tally of affected rows
    // from the statements that returned none. Sets produced before an error or
    // a cancel are kept, as SSMS does.
    m_sets.clear();
    int affected = -1;
    for (const SqlResultSet& s : sets) {
        if (!s.columns.isEmpty())
            m_sets << s;
        else if (s.affected >= 0)
            affected = (affected < 0 ? 0 : affected) + s.affected;
    }
    m_affected = affected;

    m_messages.clear();
    for (const SqlMessage& m : messages)
        m_messages.append(QVariantMap{
            { QStringLiteral("kind"), m.kind == SqlMessage::Error ? QStringLiteral("error")
                                      : m.kind == SqlMessage::RowCount ? QStringLiteral("rows")
                                                                       : QStringLiteral("info") },
            { QStringLiteral("text"), m.text },
            { QStringLiteral("line"), m.line } });

    rebuildModels();
    emit resultsChanged();

    m_errorText = error;
    emit errorChanged();

    if (cancelled) {
        m_message = QStringLiteral("Query cancelled.");
        m_statusText = QStringLiteral("Cancelled.");
    } else if (!error.isEmpty()) {
        m_message.clear();
        m_statusText = m_sets.isEmpty() ? QStringLiteral("Query failed.")
                                        : QStringLiteral("Completed with errors.");
    } else if (m_sets.isEmpty()) {
        // A batch that returned no rows (e.g. UPDATE/INSERT/DDL).
        m_message = affected >= 0 ? QObject::tr("%n row(s) affected", nullptr, affected)
                                  : QStringLiteral("Command completed.");
        m_statusText = m_message;
    } else {
        m_message.clear();
        const int shown = m_result->rowCountProp();
        m_statusText = QObject::tr("%n row(s)", nullptr, shown)
                       + QStringLiteral(" · %1 ms").arg(elapsed);
    }
    emit messageChanged();
    emit statusChanged();

    setState(Connected);
    kickIdle();

    // DDL may have changed the schema: refresh the object browser and the
    // IntelliSense cache.
    static const QRegularExpression ddl(QStringLiteral("\\b(create|alter|drop)\\b"),
                                        QRegularExpression::CaseInsensitiveOption);
    if (m_batchSql.contains(ddl)) {
        emit doRefreshObjects();
        requestSchema(true);
    }

    // Background table-stats only make sense for a lone single-table SELECT.
    if (error.isEmpty() && !cancelled && m_sets.size() == 1 && !m_pendingStatsTable.isEmpty())
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
