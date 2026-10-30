#include "UpdateChecker.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSettings>
#include <QStandardPaths>
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
            "## New\n"
            "- Open several queries side by side in tabs, each keeping its own results\n"
            "- Smart autocomplete for tables, columns and SQL keywords\n"
            "## Fixed\n"
            "- Queries no longer get stuck after an error\n");
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
        m_assetUrl.clear();
        m_assetSize = 0;
        const QJsonArray assets = o.value(QStringLiteral("assets")).toArray();
        for (const QJsonValue& a : assets) {
            const QJsonObject ao = a.toObject();
            if (ao.value(QStringLiteral("name")).toString() == assetName()) {
                m_assetUrl = ao.value(QStringLiteral("browser_download_url")).toString();
                m_assetSize = qint64(ao.value(QStringLiteral("size")).toDouble());
                break;
            }
        }

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

QString UpdateChecker::assetName()
{
#if defined(Q_OS_MACOS)
    return QStringLiteral("Perch-macOS.dmg");
#elif defined(Q_OS_WIN)
    return QStringLiteral("Perch-Setup-x64.exe");
#else
    return QStringLiteral("Perch-x86_64.AppImage");
#endif
}

void UpdateChecker::startDownload()
{
    if (m_download || m_assetUrl.isEmpty())
        return;
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                        + QStringLiteral("/updates");
    QDir().mkpath(dir);
    const QString path = dir + QLatin1Char('/') + m_latest + QLatin1Char('-') + assetName();
    auto* file = new QFile(path + QStringLiteral(".part"), this);
    m_downloadError.clear();
    m_downloadedPath.clear();
    m_progress = 0;
    if (!file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        m_downloadError = tr("Couldn't save the update: %1").arg(file->errorString());
        delete file;
        emit downloadChanged();
        return;
    }

    QNetworkRequest req{QUrl(m_assetUrl)};
    req.setRawHeader("User-Agent", "Perch-Updater");
    req.setRawHeader("Accept", "application/octet-stream");
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    m_download = m_net->get(req);
    emit downloadChanged();

    connect(m_download, &QNetworkReply::readyRead, file, [this, file] {
        file->write(m_download->readAll());
    });
    connect(m_download, &QNetworkReply::downloadProgress, this, [this](qint64 got, qint64 total) {
        if (total <= 0)
            total = m_assetSize;
        if (total > 0) {
            m_progress = double(got) / double(total);
            emit downloadChanged();
        }
    });
    connect(m_download, &QNetworkReply::finished, this, [this, file, path] {
        QNetworkReply* reply = m_download;
        m_download = nullptr;
        reply->deleteLater();
        file->write(reply->readAll());
        file->close();
        const bool ok = reply->error() == QNetworkReply::NoError
                        && (m_assetSize <= 0 || file->size() == m_assetSize);
        if (ok) {
            QFile::remove(path);
            if (file->rename(path)) {
                m_downloadedPath = path;
                m_progress = 1;
            } else {
                m_downloadError = tr("Couldn't save the update.");
            }
        } else {
            if (reply->error() != QNetworkReply::OperationCanceledError)
                m_downloadError = reply->error() != QNetworkReply::NoError
                                      ? tr("Download failed: %1").arg(reply->errorString())
                                      : tr("Download was incomplete. Please try again.");
            file->remove();
        }
        file->deleteLater();
        emit downloadChanged();
    });
}

void UpdateChecker::cancelDownload()
{
    if (m_download)
        m_download->abort();
}

void UpdateChecker::installAndRestart()
{
    if (m_downloadedPath.isEmpty())
        return;
    const QString pid = QString::number(QCoreApplication::applicationPid());
    bool started = false;
#if defined(Q_OS_MACOS)
    // .../Perch.app/Contents/MacOS -> .../Perch.app
    QDir bundle(QCoreApplication::applicationDirPath());
    bundle.cdUp();
    bundle.cdUp();
    const QString app = bundle.absolutePath();
    if (app.endsWith(QStringLiteral(".app"))
        && QFileInfo(QFileInfo(app).absolutePath()).isWritable()) {
        // After Perch exits: mount the DMG, copy the new bundle next to the old
        // one, swap them, and relaunch. Falls back to opening the DMG.
        const QString script = QStringLiteral(
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done\n"
            "mnt=$(mktemp -d /tmp/perch-update.XXXXXX)\n"
            "if ! hdiutil attach -nobrowse -quiet -mountpoint \"$mnt\" \"$2\"; then open \"$2\"; exit 1; fi\n"
            "src=$(ls -d \"$mnt\"/*.app | head -n 1)\n"
            "rm -rf \"$3.new\"\n"
            "if [ -n \"$src\" ] && ditto \"$src\" \"$3.new\"; then\n"
            "  rm -rf \"$3\" && mv \"$3.new\" \"$3\"\n"
            "  xattr -dr com.apple.quarantine \"$3\" 2>/dev/null\n"
            "fi\n"
            "hdiutil detach -quiet \"$mnt\"\n"
            "open \"$3\"\n");
        started = QProcess::startDetached(QStringLiteral("/bin/sh"),
            {QStringLiteral("-c"), script, QStringLiteral("perch-update"), pid, m_downloadedPath, app});
    }
    if (!started) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(m_downloadedPath));
        return;
    }
#elif defined(Q_OS_WIN)
    // Inno Setup closes the running app, installs over it, and relaunches.
    started = QProcess::startDetached(m_downloadedPath,
        {QStringLiteral("/SILENT"), QStringLiteral("/SUPPRESSMSGBOXES"), QStringLiteral("/NORESTART"),
         QStringLiteral("/CLOSEAPPLICATIONS")});
    if (!started)
        return;
#else
    const QString appImage = qEnvironmentVariable("APPIMAGE");
    if (appImage.isEmpty() || !QFileInfo(QFileInfo(appImage).absolutePath()).isWritable()) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(m_downloadedPath).absolutePath()));
        return;
    }
    const QString script = QStringLiteral(
        "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done\n"
        "chmod +x \"$2\" && mv -f \"$2\" \"$3\"\n"
        "exec \"$3\"\n");
    started = QProcess::startDetached(QStringLiteral("/bin/sh"),
        {QStringLiteral("-c"), script, QStringLiteral("perch-update"), pid, m_downloadedPath, appImage});
    if (!started)
        return;
#endif
    QCoreApplication::quit();
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
