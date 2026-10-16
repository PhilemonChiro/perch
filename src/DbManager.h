#pragma once

#include <QList>
#include <QPointer>
#include <QQmlEngine>

#include "SqlSession.h"

// Creates and owns SQL Server sessions. QML calls open() with a connection
// string and gets back a SqlSession to drive from a console window.
class DbManager : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    static DbManager* create(QQmlEngine*, QJSEngine*);

    // Parses "[user@]host[:port][/database]" and returns a new, unconnected
    // SqlSession (call connectWith(password) to open it). Returns nullptr if the
    // host is missing. Default port 1433.
    Q_INVOKABLE SqlSession* open(const QString& target);
    // Closes and disposes a session created by open().
    Q_INVOKABLE void close(SqlSession* session);

private:
    explicit DbManager(QObject* parent = nullptr) : QObject(parent) {}
    QList<QPointer<SqlSession>> m_sessions;
};
