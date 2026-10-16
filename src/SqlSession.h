#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QThread>
#include <QVector>

#include "SqlResultModel.h"

class SqlWorker;

// One SQL Server (MSSQL) connection. All FreeTDS db-lib calls run on a worker
// thread (db-lib is single-threaded per connection); this object lives on the
// GUI thread, exposes state to QML, and marshals queries to the worker and
// result sets back. The connection password is supplied in memory via
// connectWith() and never stored on this object after it reaches the worker.
class SqlSession : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Sessions are created by DbManager")

    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString title READ title CONSTANT)
    Q_PROPERTY(QString host READ host CONSTANT)
    Q_PROPERTY(int port READ port CONSTANT)
    Q_PROPERTY(QString username READ username CONSTANT)
    Q_PROPERTY(QString database READ database CONSTANT)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)
    Q_PROPERTY(int affectedRows READ affectedRows NOTIFY messageChanged)
    Q_PROPERTY(qint64 elapsedMs READ elapsedMs NOTIFY messageChanged)
    Q_PROPERTY(QStringList tables READ tables NOTIFY tablesChanged)
    Q_PROPERTY(SqlResultModel* result READ result CONSTANT)

public:
    enum State { Idle, Connecting, Connected, Executing, Disconnected, Failed };
    Q_ENUM(State)

    SqlSession(const QString& host, int port, const QString& username, const QString& database,
               QObject* parent = nullptr);
    ~SqlSession() override;

    State state() const { return m_state; }
    QString title() const { return m_title; }
    QString host() const { return m_host; }
    int port() const { return m_port; }
    QString username() const { return m_username; }
    QString database() const { return m_database; }
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    QString message() const { return m_message; }
    int affectedRows() const { return m_affected; }
    qint64 elapsedMs() const { return m_elapsed; }
    QStringList tables() const { return m_tables; }
    SqlResultModel* result() const { return m_result; }

    // Connects using a password held only in memory. Call once per session.
    Q_INVOKABLE void connectWith(const QString& password);
    // Runs arbitrary SQL. A SELECT fills result(); other statements set message/
    // affectedRows. Ignored unless Connected.
    Q_INVOKABLE void execute(const QString& sql);
    // Closes the connection and stops the worker thread.
    Q_INVOKABLE void disconnectSession();

signals:
    void stateChanged();
    void statusChanged();
    void errorChanged();
    void messageChanged();
    void tablesChanged();

    // GUI -> worker (queued).
    void doConnect(const QString& host, int port, const QString& user,
                   const QString& password, const QString& database);
    void doExecute(const QString& sql);

private:
    void setState(State s);
    void onConnected(const QStringList& tables);
    void onFailed(const QString& error);
    void onResult(const QStringList& columns, const QVector<QStringList>& rows,
                  int affected, qint64 elapsed, const QString& message);

    const QString m_title, m_host;
    const int m_port;
    const QString m_username, m_database;

    State m_state = Idle;
    QString m_statusText, m_errorText, m_message;
    int m_affected = -1;
    qint64 m_elapsed = 0;
    QStringList m_tables;

    SqlResultModel* m_result = nullptr;
    QThread m_thread;
    SqlWorker* m_worker = nullptr;
};
