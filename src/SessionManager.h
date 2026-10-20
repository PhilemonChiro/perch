#pragma once

#include <QAbstractListModel>
#include <QPointer>
#include <QQmlEngine>

class RdpSession;

// The open tabs. Each row is a session — an RDP desktop or a SQL console —
// exposed duck-typed (title/phase/kind/hostId) so one tab strip serves both.
class SessionManager : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles { SessionRole = Qt::UserRole + 1, TitleRole, StateRole, KindRole, HostIdRole };

    static SessionManager* create(QQmlEngine*, QJSEngine*);

    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    int count() const { return int(m_sessions.size()); }

    // Opens a saved connection, or focuses its tab if already open.
    Q_INVOKABLE int openHost(const QString& hostId);
    // Opens a saved connection using a password supplied in memory, skipping the
    // async keychain read (whose job may not yet see a just-written password).
    Q_INVOKABLE int openHostWithPassword(const QString& hostId, const QString& password);
    // Reconnect a session using a saved credential set (resolves its username/domain
    // and keychain password), and remember the choice on the connection.
    Q_INVOKABLE void reconnectWithCredential(RdpSession* session, const QString& credentialId);
    // Parses "[domain\]user@host[:port]" and opens an ad-hoc RDP session.
    Q_INVOKABLE int quickConnect(const QString& text);

    // Opens a saved SQL Server connection as a tab (or focuses it).
    Q_INVOKABLE int openDatabaseHost(const QString& hostId);
    // Parses "[mssql://][user@]host[:port][/database]" and opens an ad-hoc SQL tab.
    Q_INVOKABLE int quickConnectDatabase(const QString& text);

    Q_INVOKABLE void close(int index);
    Q_INVOKABLE void move(int from, int to);
    Q_INVOKABLE QObject* at(int index) const;
    Q_INVOKABLE int indexOfHost(const QString& hostId) const;
    // Removes the stored password for a saved connection.
    Q_INVOKABLE void forgetPassword(const QString& hostId);
    Q_INVOKABLE void storePassword(const QString& hostId, const QString& password);

signals:
    void countChanged();
    void opened(int index);

private:
    explicit SessionManager(QObject* parent = nullptr);
    int add(QObject* s);
    void broadcastClipboard();

    QList<QPointer<QObject>> m_sessions;
};
