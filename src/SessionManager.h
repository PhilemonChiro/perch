#pragma once

#include <QAbstractListModel>
#include <QPointer>
#include <QQmlEngine>

class RdpSession;

// The open tabs. Each row is one RdpSession.
class SessionManager : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles { SessionRole = Qt::UserRole + 1, TitleRole, StateRole, HostIdRole };

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
    // Parses "[domain\]user@host[:port]" and opens an ad-hoc session.
    Q_INVOKABLE int quickConnect(const QString& text);
    Q_INVOKABLE void close(int index);
    Q_INVOKABLE void move(int from, int to);
    Q_INVOKABLE RdpSession* at(int index) const;
    Q_INVOKABLE int indexOfHost(const QString& hostId) const;
    // Removes the stored password for a saved connection.
    Q_INVOKABLE void forgetPassword(const QString& hostId);
    Q_INVOKABLE void storePassword(const QString& hostId, const QString& password);

signals:
    void countChanged();
    void opened(int index);

private:
    explicit SessionManager(QObject* parent = nullptr);
    int add(RdpSession* s);
    void broadcastClipboard();

    QList<QPointer<RdpSession>> m_sessions;
};
