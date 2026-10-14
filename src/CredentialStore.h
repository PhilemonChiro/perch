#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>

// Named, reusable credential sets (label + username + domain; the password lives
// in the system keychain). Connections reference one by id, so editing a set
// updates every connection that uses it.
class CredentialStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int count READ count NOTIFY changed)

public:
    static CredentialStore* instance();
    static CredentialStore* create(QQmlEngine*, QJSEngine*);

    int count() const { return int(m_creds.size()); }

    // [{ id, label, username, domain }] — passwords are never returned here.
    Q_INVOKABLE QVariantList list() const;
    Q_INVOKABLE QVariantMap get(const QString& id) const;
    // { id?, label, username, domain, password? } -> id. A non-empty password is
    // written to the keychain; an empty one on an existing set keeps the stored one.
    Q_INVOKABLE QString save(const QVariantMap& cred);
    Q_INVOKABLE void remove(const QString& id);

    // Keychain key for a credential's password.
    static QString keychainKey(const QString& id) { return QStringLiteral("cred:") + id; }

signals:
    void changed();

private:
    explicit CredentialStore(QObject* parent = nullptr);

    struct Cred {
        QString id, label, username, domain;
    };
    int indexOf(const QString& id) const;
    QVariantMap toMap(const Cred& c) const;
    void load();
    void persist() const;
    static QString storePath();
    static QString newId();

    QVector<Cred> m_creds;
};
