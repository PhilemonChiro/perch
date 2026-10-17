#pragma once

#include <QJsonArray>
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

// Saved SQL queries, persisted to disk and grouped by the server they belong to
// (keyed as "host:port"). Lets a user keep a library of queries per database
// server and recall them in any session connected to that server.
class QueryStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit QueryStore(QObject* parent = nullptr);
    static QueryStore* create(QQmlEngine*, QJSEngine*);

    // Saved queries for a server, most-recently-updated first. Each entry is a
    // map with id, name, sql and updated (ISO string).
    Q_INVOKABLE QVariantList forServer(const QString& server) const;
    // Saves a new query for a server; returns its id.
    Q_INVOKABLE QString save(const QString& server, const QString& name, const QString& sql);
    // Replaces the SQL of an existing saved query (and bumps its timestamp).
    Q_INVOKABLE void updateSql(const QString& id, const QString& sql);
    // Renames a saved query.
    Q_INVOKABLE void rename(const QString& id, const QString& name);
    // Deletes a saved query.
    Q_INVOKABLE void remove(const QString& id);

signals:
    // Emitted whenever the set of queries for `server` changed, so views refresh.
    void changed(const QString& server);

private:
    void load();
    void persist();

    QJsonArray m_items; // each: { id, server, name, sql, updated }
};
