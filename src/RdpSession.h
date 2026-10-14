#pragma once

#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQmlEngine>
#include <QSize>
#include <QVariantMap>
#include <QWaitCondition>

#include <atomic>
#include <functional>
#include <thread>

struct rdp_context;
struct rdp_freerdp;
struct s_cliprdr_client_context;
struct s_disp_client_context;

// One RDP connection. FreeRDP runs on a dedicated worker thread; this object
// lives on the GUI thread and exposes state to QML. The framebuffer is shared
// under m_frameMutex, and GUI->worker requests (resize, clipboard) are queued
// and signalled through a WinPR event the worker waits on.
class RdpSession : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Sessions are created by SessionManager")

    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString title READ title CONSTANT)
    Q_PROPERTY(QString host READ host CONSTANT)
    Q_PROPERTY(int port READ port CONSTANT)
    Q_PROPERTY(QString hostId READ hostId CONSTANT)
    Q_PROPERTY(QString username READ username NOTIFY credentialsChanged)
    Q_PROPERTY(QString domain READ domain NOTIFY credentialsChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    Q_PROPERTY(int stage READ stage NOTIFY statusChanged)
    Q_PROPERTY(QSize remoteSize READ remoteSize NOTIFY remoteSizeChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)
    Q_PROPERTY(QVariantMap certificate READ certificate NOTIFY certificateChanged)
    Q_PROPERTY(QString sharedFolder READ sharedFolder NOTIFY sharedFolderChanged)
    Q_PROPERTY(bool remounting READ remounting NOTIFY remountingChanged)

public:
    enum State { Idle, NeedsCredentials, Connecting, VerifyingCertificate, Connected, Disconnected, Failed };
    Q_ENUM(State)

    RdpSession(const QString& hostId, const QString& title, const QString& host, int port,
               const QString& username, const QString& domain, QObject* parent = nullptr);
    ~RdpSession() override;

    State state() const { return m_state; }
    QString title() const { return m_title; }
    QString host() const { return m_host; }
    int port() const { return m_port; }
    QString hostId() const { return m_hostId; }
    QString username() const { return m_username; }
    QString domain() const { return m_domain; }
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    int stage() const { return m_stage; }
    QSize remoteSize() const { return m_remoteSize; }
    bool hasFrame() const { return m_hasFrame; }
    QVariantMap certificate() const { return m_certificate; }
    QString sharedFolder() const { return m_sharedFolder; }
    bool remounting() const { return m_remounting; }

    void startWithPassword(const QString& password);
    void requestCredentials(const QString& error);
    // Local folder shared into the session as a redirected drive (empty = none).
    // Set before the first connect; use shareFolder() to change it live.
    void setSharedFolder(const QString& path) { m_sharedFolder = path; emit sharedFolderChanged(); }
    // Change the shared folder on a live session and reconnect to apply it (RDP
    // negotiates drive redirection at connect time). Credentials are reused.
    Q_INVOKABLE void shareFolder(const QString& path);

    Q_INVOKABLE void signIn(const QString& username, const QString& password, const QString& domain,
                            bool remember);
    Q_INVOKABLE void reconnect();
    Q_INVOKABLE void disconnect();
    // 0 = reject, 1 = trust permanently, 2 = trust for this connection only.
    Q_INVOKABLE void answerCertificate(int verdict);

    // Called by RdpView on the GUI thread.
    QImage frame() const;
    void setViewport(const QSize& physicalPixels, qreal devicePixelRatio);
    void sendMouse(quint16 flags, const QPointF& remotePos);
    void sendKey(bool down, bool repeat, quint32 rdpScancode);
    void setLocalClipboard(const QString& text);

signals:
    void stateChanged();
    void statusChanged();
    void errorTextChanged();
    void credentialsChanged();
    void remoteSizeChanged();
    void hasFrameChanged();
    void certificateChanged();
    void sharedFolderChanged();
    void remountingChanged();
    void frameUpdated();
    void connectedWithCredentials(const QString& username, const QString& domain,
                                  const QString& password, bool remember);

private:
    friend struct RdpCallbacks;

    void start();
    void stopWorker();
    void run();
    void clearRemounting();
    void setState(State s);
    void setStatus(const QString& text, int stage);
    void post(std::function<void()> fn);

    // Worker-thread hooks.
    bool onPostConnect();
    void onPostDisconnect();
    bool onDesktopResize();
    void onEndPaint();
    unsigned long onVerifyCertificate(const char* host, quint16 port, const char* subject,
                                      const char* issuer, const char* fingerprint, bool changed,
                                      const char* oldFingerprint);
    void onClipboardConnected(s_cliprdr_client_context* cliprdr);
    void onDispConnected(s_disp_client_context* disp);
    void processPending();
    void sendClipboardFormatList();
    void sendMonitorLayout(const QSize& size);
    void applyRemoteClipboard(const QByteArray& utf16, bool unicode);
    QByteArray localClipboardUtf16() const;

    // Immutable after construction.
    const QString m_hostId, m_title, m_host;
    const int m_port;

    // GUI-thread state.
    QString m_username, m_domain, m_password, m_sharedFolder;
    bool m_remember = false;
    State m_state = Idle;
    QString m_statusText, m_errorText;
    int m_stage = 0;
    QSize m_remoteSize;
    bool m_hasFrame = false;
    QVariantMap m_certificate;
    QString m_lastRemoteClipboard;

    // Worker.
    std::thread m_thread;
    std::atomic<bool> m_stop{false};
    std::atomic<bool> m_credentialsNeeded{false};
    std::atomic<bool> m_restartPending{false};
    bool m_remounting{false};
    std::atomic<bool> m_framePending{false};
    std::atomic<bool> m_live{false};
    rdp_context* m_context = nullptr;
    QMutex m_contextMutex; // guards m_context for GUI-thread input
    void* m_wakeEvent = nullptr;

    mutable QMutex m_frameMutex;
    QImage m_frame;

    mutable QMutex m_pendingMutex;
    QSize m_viewport{1600, 900};
    int m_scale = 100;
    QSize m_pendingResize;
    bool m_pendingClipboard = false;
    QString m_localClipboard;

    QMutex m_certMutex;
    QWaitCondition m_certCond;
    int m_certVerdict = -1;

    s_cliprdr_client_context* m_cliprdr = nullptr;
    s_disp_client_context* m_disp = nullptr;
    std::atomic<bool> m_dispReady{false};
    quint32 m_requestedFormat = 0;
};
