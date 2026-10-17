#include "QueryStore.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUuid>

namespace {

QString storePath()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return dir + QStringLiteral("/queries.json");
}

} // namespace

QueryStore::QueryStore(QObject* parent) : QObject(parent)
{
    load();
}

QueryStore* QueryStore::create(QQmlEngine*, QJSEngine*)
{
    static QueryStore* store = new QueryStore;
    QQmlEngine::setObjectOwnership(store, QQmlEngine::CppOwnership);
    return store;
}

void QueryStore::load()
{
    QFile f(storePath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    m_items = QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("queries")).toArray();
}

void QueryStore::persist()
{
    QFile f(storePath());
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(QJsonObject{{QStringLiteral("version"), 1},
                                      {QStringLiteral("queries"), m_items}})
                .toJson(QJsonDocument::Compact));
}

QVariantList QueryStore::forServer(const QString& server) const
{
    QVariantList out;
    for (const QJsonValue& v : m_items) {
        const QJsonObject o = v.toObject();
        if (o.value(QStringLiteral("server")).toString() != server)
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), o.value(QStringLiteral("id")).toString()},
                               {QStringLiteral("name"), o.value(QStringLiteral("name")).toString()},
                               {QStringLiteral("sql"), o.value(QStringLiteral("sql")).toString()},
                               {QStringLiteral("updated"), o.value(QStringLiteral("updated")).toString()}});
    }
    std::stable_sort(out.begin(), out.end(), [](const QVariant& a, const QVariant& b) {
        return a.toMap().value(QStringLiteral("updated")).toString()
             > b.toMap().value(QStringLiteral("updated")).toString();
    });
    return out;
}

QString QueryStore::save(const QString& server, const QString& name, const QString& sql)
{
    const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_items.append(QJsonObject{{QStringLiteral("id"), id},
                               {QStringLiteral("server"), server},
                               {QStringLiteral("name"), name.trimmed().isEmpty()
                                                            ? QStringLiteral("Untitled")
                                                            : name.trimmed()},
                               {QStringLiteral("sql"), sql},
                               {QStringLiteral("updated"), QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}});
    persist();
    emit changed(server);
    return id;
}

void QueryStore::updateSql(const QString& id, const QString& sql)
{
    for (int i = 0; i < m_items.size(); ++i) {
        QJsonObject o = m_items.at(i).toObject();
        if (o.value(QStringLiteral("id")).toString() != id)
            continue;
        o[QStringLiteral("sql")] = sql;
        o[QStringLiteral("updated")] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        m_items[i] = o;
        persist();
        emit changed(o.value(QStringLiteral("server")).toString());
        return;
    }
}

void QueryStore::rename(const QString& id, const QString& name)
{
    for (int i = 0; i < m_items.size(); ++i) {
        QJsonObject o = m_items.at(i).toObject();
        if (o.value(QStringLiteral("id")).toString() != id)
            continue;
        o[QStringLiteral("name")] = name.trimmed().isEmpty() ? QStringLiteral("Untitled") : name.trimmed();
        m_items[i] = o;
        persist();
        emit changed(o.value(QStringLiteral("server")).toString());
        return;
    }
}

void QueryStore::remove(const QString& id)
{
    for (int i = 0; i < m_items.size(); ++i) {
        const QJsonObject o = m_items.at(i).toObject();
        if (o.value(QStringLiteral("id")).toString() != id)
            continue;
        const QString server = o.value(QStringLiteral("server")).toString();
        m_items.removeAt(i);
        persist();
        emit changed(server);
        return;
    }
}
