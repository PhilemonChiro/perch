#pragma once

#include <QAbstractListModel>
#include <QQmlEngine>

// Saved connections: a tree of folders and hosts, persisted as JSON and
// exposed to QML as a flattened list of the currently visible rows.
class ConnectionStore : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int hostCount READ hostCount NOTIFY changed)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        KindRole,
        NameRole,
        HostRole,
        PortRole,
        UsernameRole,
        DomainRole,
        DepthRole,
        ExpandedRole,
        ParentRole,
        ChildCountRole,
        LastConnectedRole,
    };

    static ConnectionStore* instance();
    static ConnectionStore* create(QQmlEngine*, QJSEngine*);

    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int hostCount() const { return int(m_hosts.size()); }

    Q_INVOKABLE QString addFolder(const QString& name, const QString& parentId = {});
    Q_INVOKABLE void renameFolder(const QString& id, const QString& name);
    Q_INVOKABLE QString saveHost(const QVariantMap& host);
    Q_INVOKABLE void remove(const QString& id);
    Q_INVOKABLE void toggle(const QString& id);
    Q_INVOKABLE QVariantMap host(const QString& id) const;
    Q_INVOKABLE QString findByAddress(const QString& address, int port) const;
    Q_INVOKABLE QVariantList search(const QString& query, int limit = 8) const;
    Q_INVOKABLE QVariantList recent(int limit = 6) const;
    Q_INVOKABLE QVariantList folders() const;
    Q_INVOKABLE void touch(const QString& id);

signals:
    void changed();

private:
    explicit ConnectionStore(QObject* parent = nullptr);

    struct Folder {
        QString id, name, parentId;
        bool expanded = true;
    };
    struct Host {
        QString id, name, host, username, domain, folderId;
        int port = 3389;
        qint64 lastConnected = 0;
    };
    struct Row {
        bool folder;
        int index;
        int depth;
    };

    QString rowId(const Row& r) const;
    void appendChildren(QList<Row>& rows, const QString& parentId, int depth) const;
    void rebuild();
    void load();
    void save() const;
    int folderIndex(const QString& id) const;
    int hostIndex(const QString& id) const;
    QVariantMap hostMap(const Host& h) const;
    QString folderPath(const QString& id) const;

    QList<Folder> m_folders;
    QList<Host> m_hosts;
    QList<Row> m_rows;
};
