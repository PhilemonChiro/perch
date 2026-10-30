#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

class QNetworkAccessManager;
class QNetworkReply;

// Checks GitHub Releases for a newer version of the app and exposes the result
// (version, release notes, download URL) to QML. It can download this
// platform's release asset in-app and hand it to a small installer step that
// runs after the app quits: macOS swaps the .app bundle from the DMG, Windows
// runs the Inno Setup installer silently, Linux replaces the AppImage. Each
// relaunches Perch. When that isn't possible, the release page opens instead.
class UpdateChecker : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)
    Q_PROPERTY(bool checking READ checking NOTIFY checkingChanged)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateChanged)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateChanged)
    Q_PROPERTY(QString releaseName READ releaseName NOTIFY updateChanged)
    Q_PROPERTY(QString releaseNotes READ releaseNotes NOTIFY updateChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY updateChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY checkingChanged)
    // In-app download of this platform's release asset.
    Q_PROPERTY(bool canInstall READ canInstall NOTIFY updateChanged)
    Q_PROPERTY(bool downloading READ downloading NOTIFY downloadChanged)
    Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY downloadChanged)
    Q_PROPERTY(bool readyToInstall READ readyToInstall NOTIFY downloadChanged)
    Q_PROPERTY(QString downloadError READ downloadError NOTIFY downloadChanged)

public:
    explicit UpdateChecker(QObject* parent = nullptr);
    static UpdateChecker* create(QQmlEngine*, QJSEngine*);

    QString currentVersion() const { return m_current; }
    bool checking() const { return m_checking; }
    bool updateAvailable() const { return m_available; }
    QString latestVersion() const { return m_latest; }
    QString releaseName() const { return m_name; }
    QString releaseNotes() const { return m_notes; }
    QString releaseUrl() const { return m_url; }
    QString lastError() const { return m_error; }
    bool canInstall() const { return !m_assetUrl.isEmpty(); }
    bool downloading() const { return m_download != nullptr; }
    double downloadProgress() const { return m_progress; }
    bool readyToInstall() const { return !m_downloadedPath.isEmpty(); }
    QString downloadError() const { return m_downloadError; }

    // Queries the GitHub Releases API for the latest release.
    Q_INVOKABLE void checkForUpdates();
    // Opens the release page in the default browser.
    Q_INVOKABLE void openDownload();
    // Remembers not to prompt again for the currently offered version.
    Q_INVOKABLE void skip();
    // Downloads this platform's release asset into the cache directory.
    Q_INVOKABLE void startDownload();
    Q_INVOKABLE void cancelDownload();
    // Quits and installs the downloaded update, then relaunches Perch.
    Q_INVOKABLE void installAndRestart();

signals:
    void checkingChanged();
    void updateChanged();
    void checkFinished(bool updateFound);
    void downloadChanged();

private:
    void setChecking(bool c);
    // Returns -1, 0, or 1 comparing dotted numeric versions (ignoring a 'v'
    // prefix); any non-numeric tail falls back to a string compare.
    static int compareVersions(const QString& a, const QString& b);

    // The release asset name for this platform (e.g. "Perch-macOS.dmg").
    static QString assetName();

    QNetworkAccessManager* m_net = nullptr;
    QNetworkReply* m_download = nullptr;
    QString m_assetUrl, m_downloadedPath, m_downloadError;
    qint64 m_assetSize = 0;
    double m_progress = 0;
    QString m_current, m_latest, m_name, m_notes, m_url, m_error;
    bool m_checking = false;
    bool m_available = false;
};
