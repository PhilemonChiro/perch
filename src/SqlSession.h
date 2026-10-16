#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QVector>

#include "SqlResultModel.h"

class SqlWorker;

// One SQL Server (MSSQL) connection. All FreeTDS db-lib calls run on a worker
// thread (db-lib is single-threaded per connection); this object lives on the
// GUI thread, exposes state to QML, and marshals queries to the worker and
// result sets back.
//
// The connection is database-aware: on connect it lists every online database
// on the server; useDatabase() switches the context (USE) and reloads the table
// list for the chosen database.
//
// The live backend connection is dropped after a period of inactivity to free
// the server and stop holding the session open; the tab and its editor survive,
// and running a query (or reconnect()) re-establishes it transparently. The
// password is held only in memory for the tab's lifetime — never written to
// disk — so a resume needs no re-entry.
class SqlSession : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Sessions are created by SessionManager")

    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(int phase READ phase NOTIFY stateChanged)
    Q_PROPERTY(QString kind READ kind CONSTANT)
    Q_PROPERTY(QString title READ title CONSTANT)
    Q_PROPERTY(QString hostId READ hostId CONSTANT)
    Q_PROPERTY(QString host READ host CONSTANT)
    Q_PROPERTY(int port READ port CONSTANT)
    Q_PROPERTY(QString username READ username CONSTANT)
    Q_PROPERTY(QString database READ database CONSTANT)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)
    Q_PROPERTY(int affectedRows READ affectedRows NOTIFY messageChanged)
    Q_PROPERTY(qint64 elapsedMs READ elapsedMs NOTIFY messageChanged)
    Q_PROPERTY(QStringList databases READ databases NOTIFY databasesChanged)
    Q_PROPERTY(QString currentDatabase READ currentDatabase NOTIFY currentDatabaseChanged)
    Q_PROPERTY(QStringList tables READ tables NOTIFY tablesChanged)
    // Background-fetched stats for the single table the last SELECT read from.
    Q_PROPERTY(QString statsTable READ statsTable NOTIFY statsChanged)
    Q_PROPERTY(qint64 tableRowCount READ tableRowCount NOTIFY statsChanged)
    Q_PROPERTY(qint64 tableSizeKb READ tableSizeKb NOTIFY statsChanged)
    Q_PROPERTY(bool idle READ isIdle NOTIFY stateChanged)
    Q_PROPERTY(SqlResultModel* result READ result CONSTANT)

public:
    enum State { Idle, Connecting, Connected, Executing, Paused, Disconnected, Failed };
    Q_ENUM(State)
    // Shared, kind-agnostic lifecycle phase (matches RdpSession::phase) so the
    // tab strip and sidebar can colour both connection kinds uniformly.
    enum Phase { PhaseIdle, PhaseConnecting, PhaseLive, PhaseBusy, PhaseEnded, PhaseFailed };

    SqlSession(const QString& hostId, const QString& host, int port, const QString& username,
               const QString& database, QObject* parent = nullptr);
    ~SqlSession() override;

    State state() const { return m_state; }
    int phase() const;
    QString kind() const { return QStringLiteral("sql"); }
    QString title() const { return m_title; }
    QString hostId() const { return m_hostId; }
    QString host() const { return m_host; }
    int port() const { return m_port; }
    QString username() const { return m_username; }
    QString database() const { return m_database; }
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    QString message() const { return m_message; }
    int affectedRows() const { return m_affected; }
    qint64 elapsedMs() const { return m_elapsed; }
    QStringList databases() const { return m_databases; }
    QString currentDatabase() const { return m_currentDatabase; }
    QStringList tables() const { return m_tables; }
    QString statsTable() const { return m_statsTable; }
    qint64 tableRowCount() const { return m_tableRowCount; }
    qint64 tableSizeKb() const { return m_tableSizeKb; }
    bool isIdle() const { return m_state == Paused; }
    SqlResultModel* result() const { return m_result; }

    // Connects using a password held in memory for the tab's lifetime. When
    // `remember` is set and this is a saved connection, the password is also
    // written to the OS keychain so reopening auto-connects.
    Q_INVOKABLE void connectWith(const QString& password, bool remember = false);
    // Re-establishes a connection that was idled out (or failed), reusing the
    // in-memory password. No-op if the password was never supplied.
    Q_INVOKABLE void reconnect();
    // Runs arbitrary SQL in the current database context. If the session has
    // idled out, it reconnects first and runs the query once live ("resume").
    Q_INVOKABLE void execute(const QString& sql);
    // Switches the active database (USE) and reloads its table list.
    Q_INVOKABLE void useDatabase(const QString& name);
    // Drops the live connection but keeps the tab; reconnect()/execute() resume.
    Q_INVOKABLE void disconnectSession();
    // How long (ms) the connection may sit idle before it is paused. 0 disables.
    Q_INVOKABLE void setIdleTimeout(int ms);

signals:
    void stateChanged();
    void statusChanged();
    void errorChanged();
    void messageChanged();
    void databasesChanged();
    void currentDatabaseChanged();
    void tablesChanged();
    void statsChanged();
    // Emitted after a successful connect when the user chose to remember the
    // password for a saved connection; SessionManager writes it to the keychain.
    void rememberPassword(const QString& password);

    // GUI -> worker (queued).
    void doConnect(const QString& host, int port, const QString& user,
                   const QString& password, const QString& database);
    void doExecute(const QString& sql);
    void doUseDatabase(const QString& name);
    void doStats(const QString& table);

private:
    void setState(State s);
    void kickIdle();
    void onConnected(const QStringList& databases, const QString& currentDb, const QStringList& tables);
    void onFailed(const QString& error);
    void onResult(const QStringList& columns, const QVector<QStringList>& rows,
                  int affected, qint64 elapsed, const QString& message);
    void onSwitched(const QString& currentDb, const QStringList& tables);
    void onStats(const QString& table, qint64 rowCount, qint64 sizeKb);
    // Returns the single source table of a plain SELECT, or "" if the query
    // joins, lists several tables, or isn't a simple table read.
    static QString sourceTable(const QString& sql);

    const QString m_hostId, m_title, m_host;
    const int m_port;
    const QString m_username, m_database;

    State m_state = Idle;
    QString m_statusText, m_errorText, m_message;
    int m_affected = -1;
    qint64 m_elapsed = 0;
    QStringList m_databases, m_tables;
    QString m_currentDatabase;

    QString m_statsTable, m_pendingStatsTable;
    qint64 m_tableRowCount = -1;
    qint64 m_tableSizeKb = -1;

    QString m_password;    // in memory for the tab's lifetime (keychain only if remembered)
    QString m_pendingSql;  // a query to run once a resume completes
    bool m_haveConnected = false;
    bool m_remember = false;

    QTimer m_idleTimer;
    int m_idleTimeout = 10 * 60 * 1000; // 10 minutes

    SqlResultModel* m_result = nullptr;
    QThread m_thread;
    SqlWorker* m_worker = nullptr;
};
