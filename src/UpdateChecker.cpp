#include "UpdateChecker.h"

#include <QDesktopServices>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSettings>
#include <QUrl>

#define UC_STRINGIFY(x) #x
#define UC_TOSTRING(x) UC_STRINGIFY(x)

namespace {
#ifdef APP_VERSION
const char* kVersion = UC_TOSTRING(APP_VERSION);
#else
const char* kVersion = "0.0.0";
#endif
#ifdef UPDATE_REPO
const char* kRepo = UPDATE_REPO;
#else
const char* kRepo = "";
#endif
} // namespace

UpdateChecker::UpdateChecker(QObject* parent)
    : QObject(parent)
    , m_net(new QNetworkAccessManager(this))
    , m_current(QString::fromLatin1(kVersion))
{
}

UpdateChecker* UpdateChecker::create(QQmlEngine*, QJSEngine*)
{
    static UpdateChecker* inst = new UpdateChecker;
    QQmlEngine::setObjectOwnership(inst, QQmlEngine::CppOwnership);
    return inst;
}

void UpdateChecker::setChecking(bool c)
{
    if (m_checking == c)
        return;
    m_checking = c;
    emit checkingChanged();
}

void UpdateChecker::checkForUpdates()
{
    // Dev aid: RELAY_UPDATE_DEMO opens the update dialog with sample release
    // notes (no network), to preview the "What's new" presentation.
    if (qEnvironmentVariableIsSet("RELAY_UPDATE_DEMO")) {
        m_latest = QStringLiteral("0.2.0");
        m_name = QStringLiteral("Perch 0.2.0");
        m_notes = QStringLiteral(
            "## What's Changed\n"
            "* Add collapsible object-browser folders with per-type icons\n"
            "* Add SQL IntelliSense with table and column completion\n"
            "* Add batch row operations: copy, INSERTs, generate DELETE, export CSV\n"
            "* Add a single-instance guard so a second launch focuses the running window\n"
            "* Improve metadata fetch to read the catalog directly\n"
            "* Improve connecting with automatic retry and exponential backoff\n"
            "* Fix the Windows installer to bundle the correct x64 MSVC runtime\n"
            "* Fix a wrong-architecture DLL causing 0xc000007b at launch\n"
            "**Full Changelog**: https://github.com/PhilemonChiro/perch/compare/v0.1.4...v0.2.0\n");
        m_url = QStringLiteral("https://github.com/PhilemonChiro/perch/releases/tag/v0.2.0");
        m_available = true;
        emit updateChanged();
        emit checkFinished(true);
        return;
    }
    if (m_checking || QString::fromLatin1(kRepo).isEmpty())
        return;
    m_error.clear();
    setChecking(true);

    QNetworkRequest req(QUrl(QStringLiteral("https://api.github.com/repos/%1/releases/latest")
                                 .arg(QString::fromLatin1(kRepo))));
    req.setRawHeader("Accept", "application/vnd.github+json");
    req.setRawHeader("User-Agent", "Perch-Updater");
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);

    QNetworkReply* reply = m_net->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        setChecking(false);

        if (reply->error() != QNetworkReply::NoError) {
            m_error = reply->errorString();
            emit checkingChanged();
            emit checkFinished(false);
            return;
        }
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        const QString tag = o.value(QStringLiteral("tag_name")).toString();
        if (tag.isEmpty()) {
            m_error = QStringLiteral("No release found.");
            emit checkingChanged();
            emit checkFinished(false);
            return;
        }

        m_latest = tag;
        m_name = o.value(QStringLiteral("name")).toString();
        m_notes = o.value(QStringLiteral("body")).toString();
        m_url = o.value(QStringLiteral("html_url")).toString();

        QSettings settings;
        const QString skipped = settings.value(QStringLiteral("updates/skippedVersion")).toString();
        const bool newer = compareVersions(m_latest, m_current) > 0;
        m_available = newer && m_latest != skipped;

        emit updateChanged();
        emit checkFinished(m_available);
    });
}

void UpdateChecker::openDownload()
{
    if (!m_url.isEmpty())
        QDesktopServices::openUrl(QUrl(m_url));
}

void UpdateChecker::skip()
{
    if (m_latest.isEmpty())
        return;
    QSettings settings;
    settings.setValue(QStringLiteral("updates/skippedVersion"), m_latest);
    m_available = false;
    emit updateChanged();
}

int UpdateChecker::compareVersions(const QString& a, const QString& b)
{
    const auto norm = [](QString v) {
        v = v.trimmed();
        if (v.startsWith(QLatin1Char('v')) || v.startsWith(QLatin1Char('V')))
            v = v.mid(1);
        return v;
    };
    const QStringList pa = norm(a).split(QLatin1Char('.'));
    const QStringList pb = norm(b).split(QLatin1Char('.'));
    const int n = qMax(pa.size(), pb.size());
    for (int i = 0; i < n; ++i) {
        bool oka = false, okb = false;
        const int va = (i < pa.size() ? pa.at(i) : QStringLiteral("0")).toInt(&oka);
        const int vb = (i < pb.size() ? pb.at(i) : QStringLiteral("0")).toInt(&okb);
        if (!oka || !okb) // non-numeric component — fall back to string compare
            return QString::compare(norm(a), norm(b));
        if (va != vb)
            return va < vb ? -1 : 1;
    }
    return 0;
}
