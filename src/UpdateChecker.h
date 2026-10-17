#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

class QNetworkAccessManager;

// Checks GitHub Releases for a newer version of the app and exposes the result
// (version, release notes, download URL) to QML. It never installs anything —
// the download button opens the release page in the browser — so there is no
// code-signing or elevation involved.
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

    // Queries the GitHub Releases API for the latest release.
    Q_INVOKABLE void checkForUpdates();
    // Opens the release page in the default browser.
    Q_INVOKABLE void openDownload();
    // Remembers not to prompt again for the currently offered version.
    Q_INVOKABLE void skip();

signals:
    void checkingChanged();
    void updateChanged();
    void checkFinished(bool updateFound);

private:
    void setChecking(bool c);
    // Returns -1, 0, or 1 comparing dotted numeric versions (ignoring a 'v'
    // prefix); any non-numeric tail falls back to a string compare.
    static int compareVersions(const QString& a, const QString& b);

    QNetworkAccessManager* m_net = nullptr;
    QString m_current, m_latest, m_name, m_notes, m_url, m_error;
    bool m_checking = false;
    bool m_available = false;
};
