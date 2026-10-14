#include "CredentialStore.h"

#include "Credentials.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>

namespace {
QString dataDir()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return dir;
}
} // namespace

CredentialStore::CredentialStore(QObject* parent) : QObject(parent)
{
    load();
}

CredentialStore* CredentialStore::instance()
{
    static CredentialStore s;
    return &s;
}

CredentialStore* CredentialStore::create(QQmlEngine*, QJSEngine*)
{
    auto* s = instance();
    QQmlEngine::setObjectOwnership(s, QQmlEngine::CppOwnership);
    return s;
}

QString CredentialStore::storePath()
{
    return dataDir() + QStringLiteral("/credentials.json");
}

QString CredentialStore::newId()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

int CredentialStore::indexOf(const QString& id) const
{
    for (int i = 0; i < m_creds.size(); ++i)
        if (m_creds[i].id == id)
            return i;
    return -1;
}

QVariantMap CredentialStore::toMap(const Cred& c) const
{
    return {{"id", c.id}, {"label", c.label}, {"username", c.username}, {"domain", c.domain}};
}

QVariantList CredentialStore::list() const
{
    QVariantList out;
    for (const Cred& c : m_creds)
        out.append(toMap(c));
    return out;
}

QVariantMap CredentialStore::get(const QString& id) const
{
    const int i = indexOf(id);
    return i < 0 ? QVariantMap{} : toMap(m_creds[i]);
}

QString CredentialStore::save(const QVariantMap& cred)
{
    QString id = cred.value("id").toString();
    int i = indexOf(id);
    if (i < 0) {
        id = newId();
        m_creds.append(Cred{id, {}, {}, {}});
        i = int(m_creds.size()) - 1;
    }
    Cred& c = m_creds[i];
    c.label = cred.value("label").toString().trimmed();
    c.username = cred.value("username").toString().trimmed();
    c.domain = cred.value("domain").toString().trimmed();
    if (c.label.isEmpty())
        c.label = c.username.isEmpty() ? tr("Credential") : c.username;

    const QString password = cred.value("password").toString();
    if (!password.isEmpty())
        Credentials::write(keychainKey(id), password);

    persist();
    emit changed();
    return id;
}

void CredentialStore::remove(const QString& id)
{
    const int i = indexOf(id);
    if (i < 0)
        return;
    m_creds.removeAt(i);
    Credentials::remove(keychainKey(id));
    persist();
    emit changed();
}

void CredentialStore::load()
{
    QFile f(storePath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonArray arr = QJsonDocument::fromJson(f.readAll()).object().value("credentials").toArray();
    m_creds.clear();
    for (const QJsonValue v : arr) {
        const QJsonObject o = v.toObject();
        m_creds.append(Cred{o.value("id").toString(), o.value("label").toString(),
                            o.value("username").toString(), o.value("domain").toString()});
    }
}

void CredentialStore::persist() const
{
    QJsonArray arr;
    for (const Cred& c : m_creds)
        arr.append(QJsonObject{{"id", c.id}, {"label", c.label},
                               {"username", c.username}, {"domain", c.domain}});
    QSaveFile f(storePath());
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.write(QJsonDocument(QJsonObject{{"version", 1}, {"credentials", arr}}).toJson());
    f.commit();
}
