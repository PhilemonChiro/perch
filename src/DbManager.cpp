#include "DbManager.h"

#include <QRegularExpression>

DbManager* DbManager::create(QQmlEngine*, QJSEngine*)
{
    static DbManager* instance = new DbManager;
    return instance;
}

SqlSession* DbManager::open(const QString& target)
{
    // [user@]host[:port][/database]
    QString rest = target.trimmed();
    // Allow an optional mssql:// scheme.
    rest.remove(QRegularExpression(QStringLiteral("^(mssql|sql)://"),
                                   QRegularExpression::CaseInsensitiveOption));

    QString user, database;
    const int at = rest.indexOf(QLatin1Char('@'));
    if (at >= 0) {
        user = rest.left(at);
        rest = rest.mid(at + 1);
    }
    const int slash = rest.indexOf(QLatin1Char('/'));
    if (slash >= 0) {
        database = rest.mid(slash + 1);
        rest = rest.left(slash);
    }
    QString host = rest;
    int port = 1433;
    const int colon = rest.lastIndexOf(QLatin1Char(':'));
    if (colon >= 0) {
        host = rest.left(colon);
        const int p = rest.mid(colon + 1).toInt();
        if (p > 0)
            port = p;
    }
    if (host.isEmpty())
        return nullptr;

    auto* s = new SqlSession(host, port, user, database, this);
    QQmlEngine::setObjectOwnership(s, QQmlEngine::CppOwnership);
    m_sessions.append(s);
    return s;
}

void DbManager::close(SqlSession* session)
{
    if (!session)
        return;
    m_sessions.removeAll(session);
    session->disconnectSession();
    session->deleteLater();
}
