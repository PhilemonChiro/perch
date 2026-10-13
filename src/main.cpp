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
    app.setApplicationVersion(QStringLiteral("0.1.0"));

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
