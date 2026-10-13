#include "SessionManager.h"

#include "ConnectionStore.h"
#include "Credentials.h"
#include "RdpSession.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QRegularExpression>

SessionManager::SessionManager(QObject* parent)
    : QAbstractListModel(parent)
{
    connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this,
            &SessionManager::broadcastClipboard);
}

SessionManager* SessionManager::create(QQmlEngine*, QJSEngine*)
{
    static SessionManager* mgr = new SessionManager;
    QQmlEngine::setObjectOwnership(mgr, QQmlEngine::CppOwnership);
    return mgr;
}

int SessionManager::rowCount(const QModelIndex& parent) const
{
    return parent.isValid() ? 0 : int(m_sessions.size());
}

QHash<int, QByteArray> SessionManager::roleNames() const
{
    return {{SessionRole, "session"}, {TitleRole, "title"}, {StateRole, "state"}, {HostIdRole, "hostId"}};
}

QVariant SessionManager::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_sessions.size())
        return {};
    RdpSession* s = m_sessions.at(index.row());
    if (!s)
        return {};
    switch (role) {
    case SessionRole: return QVariant::fromValue(s);
    case TitleRole: return s->title();
    case StateRole: return int(s->state());
    case HostIdRole: return s->hostId();
    default: return {};
    }
}

int SessionManager::add(RdpSession* s)
{
    const int row = int(m_sessions.size());
    beginInsertRows({}, row, row);
    m_sessions.append(s);
    endInsertRows();
    connect(s, &RdpSession::stateChanged, this, [this, s] {
        const int i = int(m_sessions.indexOf(s));
        if (i >= 0)
            emit dataChanged(index(i), index(i), {StateRole});
    });
    // Remember the password once a sign-in actually succeeds.
    connect(s, &RdpSession::connectedWithCredentials, this,
            [s](const QString& user, const QString& domain, const QString& password, bool remember) {
                if (s->hostId().isEmpty())
                    return;
                auto* store = ConnectionStore::instance();
                QVariantMap h = store->host(s->hostId());
                if (!h.isEmpty() && (h.value("username") != user || h.value("domain") != domain)) {
                    h["username"] = user;
                    h["domain"] = domain;
                    store->saveHost(h);
                }
                if (remember)
                    Credentials::write(s->hostId(), password);
                store->touch(s->hostId());
            });
    s->setLocalClipboard(QGuiApplication::clipboard()->text());
    emit countChanged();
    emit opened(row);
    return row;
}

int SessionManager::openHost(const QString& hostId)
{
    if (const int open = indexOfHost(hostId); open >= 0) {
        RdpSession* s = m_sessions.at(open);
        if (s->state() == RdpSession::Disconnected || s->state() == RdpSession::Failed)
            s->reconnect();
        emit opened(open);
        return open;
    }
    const QVariantMap h = ConnectionStore::instance()->host(hostId);
    if (h.isEmpty())
        return -1;
    auto* s = new RdpSession(hostId, h.value("name").toString(), h.value("host").toString(),
                             h.value("port").toInt(), h.value("username").toString(),
                             h.value("domain").toString(), this);
    const int row = add(s);
    QPointer<RdpSession> guard(s);
    Credentials::read(hostId, [guard](bool found, const QString& password) {
        if (!guard)
            return;
        if (found && !guard->username().isEmpty())
            guard->startWithPassword(password);
        else
            guard->requestCredentials(QString());
    });
    return row;
}

int SessionManager::openHostWithPassword(const QString& hostId, const QString& password)
{
    if (const int open = indexOfHost(hostId); open >= 0) {
        RdpSession* s = m_sessions.at(open);
        s->startWithPassword(password);
        emit opened(open);
        return open;
    }
    const QVariantMap h = ConnectionStore::instance()->host(hostId);
    if (h.isEmpty())
        return -1;
    auto* s = new RdpSession(hostId, h.value("name").toString(), h.value("host").toString(),
                             h.value("port").toInt(), h.value("username").toString(),
                             h.value("domain").toString(), this);
    const int row = add(s);
    s->startWithPassword(password);
    return row;
}

int SessionManager::quickConnect(const QString& text)
{
    static const QRegularExpression re(
        QStringLiteral(R"(^\s*(?:(?:([^\\@\s]+)\\)?([^@\s]+)@)?(\[[^\]]+\]|[^:\s]+)(?::(\d+))?\s*$)"));
    const auto m = re.match(text);
    if (!m.hasMatch())
        return -1;
    const QString domain = m.captured(1);
    const QString user = m.captured(2);
    QString host = m.captured(3);
    if (host.startsWith('[') && host.endsWith(']'))
        host = host.mid(1, host.size() - 2);
    const int port = m.captured(4).isEmpty() ? 3389 : m.captured(4).toInt();

    const QString saved = ConnectionStore::instance()->findByAddress(host, port);
    if (!saved.isEmpty() && user.isEmpty())
        return openHost(saved);

    auto* s = new RdpSession(QString(), host, host, port, user, domain, this);
    const int row = add(s);
    s->requestCredentials(QString());
    return row;
}

void SessionManager::close(int i)
{
    if (i < 0 || i >= m_sessions.size())
        return;
    beginRemoveRows({}, i, i);
    RdpSession* s = m_sessions.takeAt(i);
    endRemoveRows();
    if (s)
        s->deleteLater();
    emit countChanged();
}

void SessionManager::move(int from, int to)
{
    if (from == to || from < 0 || to < 0 || from >= m_sessions.size() || to >= m_sessions.size())
        return;
    if (!beginMoveRows({}, from, from, {}, to > from ? to + 1 : to))
        return;
    m_sessions.move(from, to);
    endMoveRows();
}

RdpSession* SessionManager::at(int i) const
{
    return i >= 0 && i < m_sessions.size() ? m_sessions.at(i).data() : nullptr;
}

int SessionManager::indexOfHost(const QString& hostId) const
{
    if (hostId.isEmpty())
        return -1;
    for (int i = 0; i < m_sessions.size(); ++i)
        if (m_sessions[i] && m_sessions[i]->hostId() == hostId)
            return i;
    return -1;
}

void SessionManager::forgetPassword(const QString& hostId)
{
    Credentials::remove(hostId);
}

void SessionManager::storePassword(const QString& hostId, const QString& password)
{
    if (!hostId.isEmpty() && !password.isEmpty())
        Credentials::write(hostId, password);
}

void SessionManager::broadcastClipboard()
{
    const QString text = QGuiApplication::clipboard()->text();
    for (const auto& s : std::as_const(m_sessions))
        if (s)
            s->setLocalClipboard(text);
}
