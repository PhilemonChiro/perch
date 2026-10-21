#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

#include "RdpSession.h"
#include "SqlSession.h"
#include "SessionManager.h"

int main(int argc, char* argv[])
{
    if (!qEnvironmentVariableIsSet("WLOG_LEVEL"))
        qputenv("WLOG_LEVEL", "WARN");
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    app.setApplicationName("Relay");
    app.setOrganizationName("Relay");
    app.setApplicationVersion(QStringLiteral("0.1.5"));

    // Single instance: if another Perch is already running, ask it to come to
    // the front and exit instead of opening a second window. Keyed per user so
    // separate accounts on one machine each get their own instance.
    const QString kInstanceKey = QStringLiteral("perch.single-instance.")
                                 + QString::number(qHash(QDir::homePath()));
    {
        QLocalSocket probe;
        probe.connectToServer(kInstanceKey);
        if (probe.waitForConnected(200)) {
            probe.write("activate");
            probe.flush();
            probe.waitForBytesWritten(200);
            return 0;
        }
    }
    QLocalServer instanceServer;
    QLocalServer::removeServer(kInstanceKey); // clear a stale socket from a crash
    instanceServer.listen(kInstanceKey);

#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    // NLA authenticates with NTLM, whose password hash is MD4 (and whose key
    // exchange uses RC4). OpenSSL 3/4 keeps both in its "legacy" provider,
    // which is not loaded by default and lives at a build-time path absent on
    // users' machines — so FreeRDP's MD4 lookup fails and NLA aborts with
    // SEC_E_NO_CREDENTIALS even for correct credentials. When we run from a
    // package that ships the provider, point OpenSSL at it and activate it (via
    // the bundled openssl.cnf) before any TLS use. Dev builds have no such
    // directory and are left on the system OpenSSL.
#  ifdef Q_OS_MACOS
    const QString mod = app.applicationDirPath() + QStringLiteral("/../Frameworks/ossl-modules");
    const QString provider = mod + QStringLiteral("/legacy.dylib");
#  else
    const QString mod = app.applicationDirPath() + QStringLiteral("/ossl-modules");
    const QString provider = mod + QStringLiteral("/legacy.dll");
#  endif
    if (QFileInfo::exists(provider)) {
        qputenv("OPENSSL_MODULES", QFile::encodeName(QDir::cleanPath(mod)));
        qputenv("OPENSSL_CONF", QFile::encodeName(QDir::cleanPath(mod + QStringLiteral("/openssl.cnf"))));
    }
#endif

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Relay", "Main");

    // A second launch pings us here — raise and focus the existing window.
    QObject::connect(&instanceServer, &QLocalServer::newConnection, &app, [&engine, &instanceServer] {
        if (QLocalSocket* c = instanceServer.nextPendingConnection())
            c->deleteLater();
        if (auto* w = qobject_cast<QQuickWindow*>(engine.rootObjects().value(0))) {
            w->show();
            w->raise();
            w->requestActivate();
        }
    });

    // Dev aid: RELAY_CONNECT=user@host:port (+ RELAY_PASSWORD, RELAY_TRUST=1|2) opens a session.
    if (const QString target = qEnvironmentVariable("RELAY_CONNECT"); !target.isEmpty()) {
        QTimer::singleShot(300, [target] {
            auto* mgr = SessionManager::create(nullptr, nullptr);
            RdpSession* s = qobject_cast<RdpSession*>(mgr->at(mgr->quickConnect(target)));
            if (!s)
                return;
            if (const int trust = qEnvironmentVariableIntValue("RELAY_TRUST"))
                QObject::connect(s, &RdpSession::certificateChanged, s, [s, trust] {
                    if (!s->certificate().isEmpty())
                        s->answerCertificate(trust);
                });
            if (qEnvironmentVariableIsSet("RELAY_PASSWORD"))
                s->signIn(s->username(), qEnvironmentVariable("RELAY_PASSWORD"), s->domain(), false);
        });
    }

    // Dev aid: RELAY_SQL=[user@]host[:port][/db] opens a SQL Server console tab.
    // Optional RELAY_SQL_PASSWORD connects it; RELAY_SQL_QUERY runs once live.
    if (const QString t = qEnvironmentVariable("RELAY_SQL"); !t.isEmpty()) {
        QTimer::singleShot(300, [t] {
            auto* mgr = SessionManager::create(nullptr, nullptr);
            auto* s = qobject_cast<SqlSession*>(mgr->at(mgr->quickConnectDatabase(t)));
            if (!s)
                return;
            if (qEnvironmentVariableIsSet("RELAY_SQL_QUERY"))
                QObject::connect(s, &SqlSession::stateChanged, s, [s] {
                    if (s->state() == SqlSession::Connected && s->result()->rowCountProp() == 0)
                        s->execute(qEnvironmentVariable("RELAY_SQL_QUERY"));
                });
            if (qEnvironmentVariableIsSet("RELAY_SQL_PASSWORD"))
                s->connectWith(qEnvironmentVariable("RELAY_SQL_PASSWORD"));
        });
    }

    // Dev aid: RELAY_SCREENSHOT=out.png saves the window after startup and exits.
    if (const QString shot = qEnvironmentVariable("RELAY_SCREENSHOT"); !shot.isEmpty()) {
        const int delay = qEnvironmentVariableIntValue("RELAY_SCREENSHOT_DELAY");
        QTimer::singleShot(delay > 0 ? delay : 2500, [&engine, shot] {
            if (auto* w = qobject_cast<QQuickWindow*>(engine.rootObjects().value(0)))
                w->grabWindow().save(shot);
            QCoreApplication::quit();
        });
    }
    return app.exec();
}
