#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

#include "RdpSession.h"
#include "SessionManager.h"

int main(int argc, char* argv[])
{
    if (!qEnvironmentVariableIsSet("WLOG_LEVEL"))
        qputenv("WLOG_LEVEL", "WARN");
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    app.setApplicationName("Relay");
    app.setOrganizationName("Relay");
    app.setApplicationVersion(QStringLiteral("0.1.2"));

#ifdef Q_OS_MACOS
    // NLA authenticates with NTLM, whose password hash is MD4 (and whose key
    // exchange uses RC4). OpenSSL 3/4 keeps both in its "legacy" provider,
    // which is not loaded by default and lives at a Homebrew path absent on
    // users' Macs — so FreeRDP's MD4 lookup fails and NLA aborts with
    // SEC_E_NO_CREDENTIALS even for correct credentials. When we run from a
    // bundle that ships the provider, point OpenSSL at it and activate it (via
    // the bundled openssl.cnf) before any TLS use. Dev builds have no such
    // directory and are left on the system OpenSSL.
    if (const QString mod = app.applicationDirPath() + QStringLiteral("/../Frameworks/ossl-modules");
        QFileInfo::exists(mod + QStringLiteral("/legacy.dylib"))) {
        qputenv("OPENSSL_MODULES", QFile::encodeName(QDir::cleanPath(mod)));
        qputenv("OPENSSL_CONF", QFile::encodeName(QDir::cleanPath(mod + QStringLiteral("/openssl.cnf"))));
    }
#endif

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Relay", "Main");

    // Dev aid: RELAY_CONNECT=user@host:port (+ RELAY_PASSWORD, RELAY_TRUST=1|2) opens a session.
    if (const QString target = qEnvironmentVariable("RELAY_CONNECT"); !target.isEmpty()) {
        QTimer::singleShot(300, [target] {
            auto* mgr = SessionManager::create(nullptr, nullptr);
            RdpSession* s = mgr->at(mgr->quickConnect(target));
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
