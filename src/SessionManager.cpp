#include "SessionManager.h"

#include "ConnectionStore.h"
#include "CredentialStore.h"
#include "Credentials.h"
#include "RdpSession.h"
#include "SqlSession.h"

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
    return {{SessionRole, "session"}, {TitleRole, "title"}, {StateRole, "state"},
            {KindRole, "kind"}, {HostIdRole, "hostId"}};
}

QVariant SessionManager::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_sessions.size())
        return {};
    QObject* s = m_sessions.at(index.row());
    if (!s)
        return {};
    switch (role) {
    case SessionRole: return QVariant::fromValue(s);
    case TitleRole: return s->property("title");
    case StateRole: return s->property("phase"); // kind-agnostic lifecycle phase
    case KindRole: return s->property("kind");
    case HostIdRole: return s->property("hostId");
    default: return {};
    }
}

int SessionManager::add(QObject* s)
{
    const int row = int(m_sessions.size());
    beginInsertRows({}, row, row);
    m_sessions.append(s);
    endInsertRows();

    // Re-emit the row's state when the session's phase changes (both kinds have
    // a stateChanged signal driving their phase).
    const auto emitState = [this, s] {
        for (int i = 0; i < m_sessions.size(); ++i)
            if (m_sessions[i] == s) {
                emit dataChanged(index(i), index(i), {StateRole});
                break;
            }
    };

    if (auto* r = qobject_cast<RdpSession*>(s)) {
        connect(r, &RdpSession::stateChanged, this, emitState);
        // Remember the password once a sign-in actually succeeds.
        connect(r, &RdpSession::connectedWithCredentials, this,
                [r](const QString& user, const QString& domain, const QString& password, bool remember) {
                    if (r->hostId().isEmpty())
                        return;
                    auto* store = ConnectionStore::instance();
                    QVariantMap h = store->host(r->hostId());
                    if (!h.isEmpty() && (h.value("username") != user || h.value("domain") != domain)) {
                        h["username"] = user;
                        h["domain"] = domain;
                        store->saveHost(h);
                    }
                    if (remember)
                        Credentials::write(r->hostId(), password);
                    store->touch(r->hostId());
                });
        r->setLocalClipboard(QGuiApplication::clipboard()->text());
    } else if (auto* q = qobject_cast<SqlSession*>(s)) {
        connect(q, &SqlSession::stateChanged, this, emitState);
        connect(q, &SqlSession::stateChanged, this, [q] {
            if (q->state() == SqlSession::Connected && !q->hostId().isEmpty())
                ConnectionStore::instance()->touch(q->hostId());
        });
        // Persist the password to the keychain when the user asked to remember it.
        connect(q, &SqlSession::rememberPassword, this, [q](const QString& pw) {
            if (!q->hostId().isEmpty())
                Credentials::write(q->hostId(), pw);
        });
    }

    emit countChanged();
    emit opened(row);
    return row;
}

int SessionManager::openHost(const QString& hostId)
{
    if (const int open = indexOfHost(hostId); open >= 0) {
        if (auto* s = qobject_cast<RdpSession*>(m_sessions.at(open).data())) {
            if (s->state() == RdpSession::Disconnected || s->state() == RdpSession::Failed)
                s->reconnect();
        }
        emit opened(open);
        return open;
    }
    const QVariantMap h = ConnectionStore::instance()->host(hostId);
    if (h.isEmpty())
        return -1;
    if (const QString t = h.value("type").toString();
        t == QLatin1String("mssql") || t == QLatin1String("postgres"))
        return openDatabaseHost(hostId);
    // A connection may reference a saved credential set; otherwise it uses its
    // own inline username/domain with the password stored under the host id.
    QString username = h.value("username").toString();
    QString domain = h.value("domain").toString();
    QString passwordKey = hostId;
    if (const QString credId = h.value("credentialId").toString(); !credId.isEmpty()) {
        const QVariantMap cred = CredentialStore::instance()->get(credId);
        if (!cred.isEmpty()) {
            username = cred.value("username").toString();
            domain = cred.value("domain").toString();
            passwordKey = CredentialStore::keychainKey(credId);
        }
    }
    auto* s = new RdpSession(hostId, h.value("name").toString(), h.value("host").toString(),
                             h.value("port").toInt(), username, domain, this);
    s->setSharedFolder(h.value("share").toString());
    s->setGateway(h.value("gateway").toString());
    s->setUseUdp(h.value("useUdp").toBool());
    s->setCredentialId(h.value("credentialId").toString());
    const int row = add(s);
    QPointer<RdpSession> guard(s);
    Credentials::read(passwordKey, [guard](bool found, const QString& password) {
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
        if (auto* s = qobject_cast<RdpSession*>(m_sessions.at(open).data()))
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
    s->setSharedFolder(h.value("share").toString());
    s->setGateway(h.value("gateway").toString());
    s->setUseUdp(h.value("useUdp").toBool());
    s->setCredentialId(h.value("credentialId").toString());
    const int row = add(s);
    s->startWithPassword(password);
    return row;
}

void SessionManager::reconnectWithCredential(RdpSession* s, const QString& credentialId)
{
    if (!s)
        return;
    const QVariantMap c = CredentialStore::instance()->get(credentialId);
    if (c.isEmpty())
        return;
    const QString user = c.value("username").toString();
    const QString dom = c.value("domain").toString();
    if (!s->hostId().isEmpty())
        ConnectionStore::instance()->setCredential(s->hostId(), credentialId);
    s->setCredentialId(credentialId);
    QPointer<RdpSession> guard(s);
    Credentials::read(CredentialStore::keychainKey(credentialId),
                      [guard, user, dom](bool, const QString& pw) {
                          if (guard)
                              guard->signIn(user, pw, dom, false);
                      });
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

int SessionManager::openDatabaseHost(const QString& hostId)
{
    if (const int open = indexOfHost(hostId); open >= 0) {
        emit opened(open);
        return open;
    }
    const QVariantMap h = ConnectionStore::instance()->host(hostId);
    if (h.isEmpty())
        return -1;
    const QString engine = h.value("type").toString() == QLatin1String("postgres")
                               ? QStringLiteral("postgres")
                               : QStringLiteral("mssql");
    const int defPort = engine == QLatin1String("postgres") ? 5432 : 1433;
    const int port = h.value("port").toInt() > 0 ? h.value("port").toInt() : defPort;
    auto* s = new SqlSession(hostId, h.value("host").toString(), port,
                             h.value("username").toString(), h.value("database").toString(),
                             engine, this);
    const int row = add(s);
    // Auto-connect with a remembered keychain password, if one is stored.
    QPointer<SqlSession> guard(s);
    Credentials::read(hostId, [guard](bool found, const QString& pw) {
        if (guard && found && !pw.isEmpty())
            guard->connectWith(pw, true);
    });
    return row;
}

int SessionManager::quickConnectDatabase(const QString& text)
{
    QString rest = text.trimmed();
    static const QRegularExpression scheme(QStringLiteral("^(postgres|postgresql|pg|mssql|sql)://"),
                                           QRegularExpression::CaseInsensitiveOption);
    const auto sm = scheme.match(rest);
    const QString engine = (sm.hasMatch()
                            && sm.captured(1).compare(QLatin1String("mssql"), Qt::CaseInsensitive) != 0
                            && sm.captured(1).compare(QLatin1String("sql"), Qt::CaseInsensitive) != 0)
                               ? QStringLiteral("postgres")
                               : QStringLiteral("mssql");
    rest.remove(scheme);
    QString user, database;
    if (const int at = rest.indexOf(QLatin1Char('@')); at >= 0) {
        user = rest.left(at);
        rest = rest.mid(at + 1);
    }
    if (const int slash = rest.indexOf(QLatin1Char('/')); slash >= 0) {
        database = rest.mid(slash + 1);
        rest = rest.left(slash);
    }
    QString host = rest;
    int port = engine == QLatin1String("postgres") ? 5432 : 1433;
    if (const int colon = rest.lastIndexOf(QLatin1Char(':')); colon >= 0) {
        host = rest.left(colon);
        if (const int p = rest.mid(colon + 1).toInt(); p > 0)
            port = p;
    }
    if (host.isEmpty())
        return -1;
    auto* s = new SqlSession(QString(), host, port, user, database, engine, this);
    return add(s);
}

void SessionManager::close(int i)
{
    if (i < 0 || i >= m_sessions.size())
        return;
    beginRemoveRows({}, i, i);
    QObject* s = m_sessions.takeAt(i);
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

QObject* SessionManager::at(int i) const
{
    return i >= 0 && i < m_sessions.size() ? m_sessions.at(i).data() : nullptr;
}

int SessionManager::indexOfHost(const QString& hostId) const
{
    if (hostId.isEmpty())
        return -1;
    for (int i = 0; i < m_sessions.size(); ++i)
        if (m_sessions[i] && m_sessions[i]->property("hostId").toString() == hostId)
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
        if (auto* r = qobject_cast<RdpSession*>(s.data()))
            r->setLocalClipboard(text);
}
