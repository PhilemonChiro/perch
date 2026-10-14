#include "ConnectionStore.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>

#include <algorithm>
#include <functional>

namespace {

QString storePath()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return dir + QStringLiteral("/connections.json");
}

QString newId()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

// Scores how well `query` matches `text`: exact prefix > word prefix >
// substring > in-order subsequence. Returns 0 for no match.
int fuzzyScore(const QString& text, const QString& query)
{
    if (query.isEmpty())
        return 1;
    const QString t = text.toLower();
    const QString q = query.toLower();
    if (t.startsWith(q))
        return 1000 - int(t.size());
    const int at = int(t.indexOf(q));
    if (at > 0) {
        const QChar before = t.at(at - 1);
        const bool wordStart = !before.isLetterOrNumber();
        return (wordStart ? 800 : 600) - at;
    }
    int ti = 0, score = 0, streak = 0;
    for (const QChar c : q) {
        bool found = false;
        while (ti < t.size()) {
            if (t.at(ti++) == c) {
                found = true;
                break;
            }
            streak = 0;
        }
        if (!found)
            return 0;
        score += 10 + streak * 5;
        ++streak;
    }
    return score;
}

} // namespace

ConnectionStore::ConnectionStore(QObject* parent)
    : QAbstractListModel(parent)
{
    load();
    rebuild();
}

ConnectionStore* ConnectionStore::instance()
{
    static ConnectionStore* store = new ConnectionStore;
    return store;
}

ConnectionStore* ConnectionStore::create(QQmlEngine*, QJSEngine*)
{
    auto* s = instance();
    QQmlEngine::setObjectOwnership(s, QQmlEngine::CppOwnership);
    return s;
}

int ConnectionStore::rowCount(const QModelIndex& parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

QHash<int, QByteArray> ConnectionStore::roleNames() const
{
    return {
        {IdRole, "itemId"},
        {KindRole, "kind"},
        {NameRole, "name"},
        {HostRole, "host"},
        {PortRole, "port"},
        {UsernameRole, "username"},
        {DomainRole, "domain"},
        {DepthRole, "depth"},
        {ExpandedRole, "expanded"},
        {ParentRole, "parentId"},
        {ChildCountRole, "childCount"},
        {LastConnectedRole, "lastConnected"},
    };
}

QVariant ConnectionStore::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size())
        return {};
    const Row& r = m_rows.at(index.row());
    if (role == DepthRole)
        return r.depth;
    if (role == KindRole)
        return r.folder ? QStringLiteral("folder") : QStringLiteral("host");

    if (r.folder) {
        const Folder& f = m_folders.at(r.index);
        switch (role) {
        case IdRole: return f.id;
        case NameRole: return f.name;
        case ExpandedRole: return f.expanded;
        case ParentRole: return f.parentId;
        case ChildCountRole: {
            int n = 0;
            for (const Host& h : m_hosts)
                n += h.folderId == f.id;
            for (const Folder& c : m_folders)
                n += c.parentId == f.id;
            return n;
        }
        default: return {};
        }
    }

    const Host& h = m_hosts.at(r.index);
    switch (role) {
    case IdRole: return h.id;
    case NameRole: return h.name.isEmpty() ? h.host : h.name;
    case HostRole: return h.host;
    case PortRole: return h.port;
    case UsernameRole: return h.username;
    case DomainRole: return h.domain;
    case ParentRole: return h.folderId;
    case LastConnectedRole: return h.lastConnected;
    default: return {};
    }
}

QString ConnectionStore::rowId(const Row& r) const
{
    return r.id;
}

void ConnectionStore::appendChildren(QList<Row>& rows, const QString& parentId, int depth) const
{
    QList<int> folders, hosts;
    for (int i = 0; i < m_folders.size(); ++i)
        if (m_folders[i].parentId == parentId)
            folders << i;
    for (int i = 0; i < m_hosts.size(); ++i)
        if (m_hosts[i].folderId == parentId)
            hosts << i;
    const auto byName = [](const QString& a, const QString& b) {
        return QString::compare(a, b, Qt::CaseInsensitive) < 0;
    };
    std::sort(folders.begin(), folders.end(),
              [&](int a, int b) { return byName(m_folders[a].name, m_folders[b].name); });
    std::sort(hosts.begin(), hosts.end(), [&](int a, int b) {
        const Host& x = m_hosts[a];
        const Host& y = m_hosts[b];
        return byName(x.name.isEmpty() ? x.host : x.name, y.name.isEmpty() ? y.host : y.name);
    });
    for (int i : folders) {
        rows.append({true, i, depth, m_folders[i].id});
        if (m_folders[i].expanded)
            appendChildren(rows, m_folders[i].id, depth + 1);
    }
    for (int i : hosts)
        rows.append({false, i, depth, m_hosts[i].id});
}

// Rebuilds the visible rows and reports the change as one contiguous
// remove + insert so QML views can animate expand/collapse/add/remove.
void ConnectionStore::rebuild()
{
    QList<Row> next;
    appendChildren(next, QString(), 0);

    QStringList oldIds, newIds;
    for (const Row& r : std::as_const(m_rows))
        oldIds << rowId(r);
    for (const Row& r : std::as_const(next))
        newIds << rowId(r);

    int prefix = 0;
    while (prefix < oldIds.size() && prefix < newIds.size() && oldIds[prefix] == newIds[prefix])
        ++prefix;
    int suffix = 0;
    while (suffix < oldIds.size() - prefix && suffix < newIds.size() - prefix
           && oldIds[oldIds.size() - 1 - suffix] == newIds[newIds.size() - 1 - suffix])
        ++suffix;

    const int removeEnd = int(oldIds.size()) - suffix;
    const int insertEnd = int(newIds.size()) - suffix;
    if (removeEnd > prefix) {
        beginRemoveRows({}, prefix, removeEnd - 1);
        m_rows.remove(prefix, removeEnd - prefix);
        endRemoveRows();
    }
    if (insertEnd > prefix) {
        beginInsertRows({}, prefix, insertEnd - 1);
        m_rows = next;
        endInsertRows();
    } else {
        m_rows = next;
    }
    if (!m_rows.isEmpty())
        emit dataChanged(index(0), index(int(m_rows.size()) - 1));
    emit changed();
}

void ConnectionStore::load()
{
    QFile f(storePath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    for (const QJsonValue v : root.value("folders").toArray()) {
        const QJsonObject o = v.toObject();
        m_folders.append({o.value("id").toString(), o.value("name").toString(),
                          o.value("parentId").toString(), o.value("expanded").toBool(true)});
    }
    for (const QJsonValue v : root.value("hosts").toArray()) {
        const QJsonObject o = v.toObject();
        Host h;
        h.id = o.value("id").toString();
        h.name = o.value("name").toString();
        h.host = o.value("host").toString();
        h.port = o.value("port").toInt(3389);
        h.username = o.value("username").toString();
        h.domain = o.value("domain").toString();
        h.folderId = o.value("folderId").toString();
        h.share = o.value("share").toString();
        h.gateway = o.value("gateway").toString();
        h.lastConnected = qint64(o.value("lastConnected").toDouble());
        m_hosts.append(h);
    }
}

void ConnectionStore::save() const
{
    QJsonArray folders, hosts;
    for (const Folder& f : m_folders)
        folders.append(QJsonObject{{"id", f.id}, {"name", f.name}, {"parentId", f.parentId},
                                   {"expanded", f.expanded}});
    for (const Host& h : m_hosts)
        hosts.append(QJsonObject{{"id", h.id}, {"name", h.name}, {"host", h.host},
                                 {"port", h.port}, {"username", h.username},
                                 {"domain", h.domain}, {"folderId", h.folderId},
                                 {"share", h.share}, {"gateway", h.gateway},
                                 {"lastConnected", double(h.lastConnected)}});
    QSaveFile f(storePath());
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.write(QJsonDocument(QJsonObject{{"version", 1}, {"folders", folders}, {"hosts", hosts}})
                .toJson());
    f.commit();
}

int ConnectionStore::folderIndex(const QString& id) const
{
    for (int i = 0; i < m_folders.size(); ++i)
        if (m_folders[i].id == id)
            return i;
    return -1;
}

int ConnectionStore::hostIndex(const QString& id) const
{
    for (int i = 0; i < m_hosts.size(); ++i)
        if (m_hosts[i].id == id)
            return i;
    return -1;
}

QString ConnectionStore::folderPath(const QString& id) const
{
    QStringList parts;
    QString cur = id;
    for (int guard = 0; !cur.isEmpty() && guard < 32; ++guard) {
        const int i = folderIndex(cur);
        if (i < 0)
            break;
        parts.prepend(m_folders[i].name);
        cur = m_folders[i].parentId;
    }
    return parts.join(QStringLiteral(" / "));
}

QVariantMap ConnectionStore::hostMap(const Host& h) const
{
    return {{"id", h.id},
            {"name", h.name.isEmpty() ? h.host : h.name},
            {"host", h.host},
            {"port", h.port},
            {"username", h.username},
            {"domain", h.domain},
            {"folderId", h.folderId},
            {"folder", folderPath(h.folderId)},
            {"share", h.share},
            {"gateway", h.gateway},
            {"lastConnected", h.lastConnected}};
}

QString ConnectionStore::addFolder(const QString& name, const QString& parentId)
{
    Folder f{newId(), name.trimmed().isEmpty() ? tr("New folder") : name.trimmed(), parentId, true};
    m_folders.append(f);
    if (const int p = folderIndex(parentId); p >= 0)
        m_folders[p].expanded = true;
    save();
    rebuild();
    return f.id;
}

void ConnectionStore::renameFolder(const QString& id, const QString& name)
{
    const int i = folderIndex(id);
    if (i < 0 || name.trimmed().isEmpty())
        return;
    m_folders[i].name = name.trimmed();
    save();
    rebuild();
}

QString ConnectionStore::saveHost(const QVariantMap& m)
{
    const QString id = m.value("id").toString();
    int i = hostIndex(id);
    if (i < 0) {
        Host h;
        h.id = newId();
        m_hosts.append(h);
        i = int(m_hosts.size()) - 1;
    }
    Host& h = m_hosts[i];
    h.name = m.value("name").toString().trimmed();
    h.host = m.value("host").toString().trimmed();
    h.port = m.value("port", 3389).toInt();
    if (h.port <= 0 || h.port > 65535)
        h.port = 3389;
    h.username = m.value("username").toString().trimmed();
    h.domain = m.value("domain").toString().trimmed();
    h.folderId = m.value("folderId").toString();
    h.share = m.value("share").toString().trimmed();
    h.gateway = m.value("gateway").toString().trimmed();
    if (const int p = folderIndex(h.folderId); p >= 0)
        m_folders[p].expanded = true;
    const QString saved = h.id;
    save();
    rebuild();
    return saved;
}

void ConnectionStore::setShare(const QString& id, const QString& path)
{
    const int i = hostIndex(id);
    if (i < 0 || m_hosts[i].share == path.trimmed())
        return;
    m_hosts[i].share = path.trimmed();
    save();
}

void ConnectionStore::remove(const QString& id)
{
    if (const int i = hostIndex(id); i >= 0) {
        m_hosts.removeAt(i);
    } else if (const int f = folderIndex(id); f >= 0) {
        // Children move up to the removed folder's parent rather than vanish.
        const QString parent = m_folders[f].parentId;
        for (Host& h : m_hosts)
            if (h.folderId == id)
                h.folderId = parent;
        for (Folder& c : m_folders)
            if (c.parentId == id)
                c.parentId = parent;
        m_folders.removeAt(f);
    } else {
        return;
    }
    save();
    rebuild();
}

void ConnectionStore::toggle(const QString& id)
{
    const int i = folderIndex(id);
    if (i < 0)
        return;
    m_folders[i].expanded = !m_folders[i].expanded;
    save();
    rebuild();
}

QVariantMap ConnectionStore::host(const QString& id) const
{
    const int i = hostIndex(id);
    return i < 0 ? QVariantMap{} : hostMap(m_hosts[i]);
}

QString ConnectionStore::findByAddress(const QString& address, int port) const
{
    for (const Host& h : m_hosts)
        if (h.host.compare(address, Qt::CaseInsensitive) == 0 && h.port == port)
            return h.id;
    return {};
}

QVariantList ConnectionStore::search(const QString& query, int limit) const
{
    struct Hit {
        int score;
        const Host* host;
    };
    QList<Hit> hits;
    const QString q = query.trimmed();
    for (const Host& h : m_hosts) {
        const int byName = fuzzyScore(h.name, q);
        const int score = std::max({byName ? byName + 50 : 0, fuzzyScore(h.host, q),
                                    fuzzyScore(h.username, q) / 2,
                                    fuzzyScore(folderPath(h.folderId), q) / 3});
        if (score > 0)
            hits.append({score, &h});
    }
    std::sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) {
        if (a.score != b.score)
            return a.score > b.score;
        return a.host->lastConnected > b.host->lastConnected;
    });
    QVariantList out;
    for (const Hit& hit : hits) {
        if (out.size() >= limit)
            break;
        out.append(hostMap(*hit.host));
    }
    return out;
}

QVariantList ConnectionStore::recent(int limit) const
{
    QList<const Host*> sorted;
    for (const Host& h : m_hosts)
        sorted.append(&h);
    std::sort(sorted.begin(), sorted.end(),
              [](const Host* a, const Host* b) { return a->lastConnected > b->lastConnected; });
    QVariantList out;
    for (const Host* h : sorted) {
        if (out.size() >= limit)
            break;
        out.append(hostMap(*h));
    }
    return out;
}

QVariantList ConnectionStore::folders() const
{
    QVariantList out;
    // Walk every folder regardless of expansion state, for pickers.
    std::function<void(const QString&, int)> walk = [&](const QString& parent, int depth) {
        QList<int> idx;
        for (int i = 0; i < m_folders.size(); ++i)
            if (m_folders[i].parentId == parent)
                idx << i;
        std::sort(idx.begin(), idx.end(), [&](int a, int b) {
            return QString::compare(m_folders[a].name, m_folders[b].name, Qt::CaseInsensitive) < 0;
        });
        for (int i : idx) {
            out.append(QVariantMap{{"id", m_folders[i].id}, {"name", m_folders[i].name}, {"depth", depth}});
            walk(m_folders[i].id, depth + 1);
        }
    };
    walk(QString(), 0);
    return out;
}

void ConnectionStore::touch(const QString& id)
{
    const int i = hostIndex(id);
    if (i < 0)
        return;
    m_hosts[i].lastConnected = QDateTime::currentMSecsSinceEpoch();
    save();
    rebuild();
}
