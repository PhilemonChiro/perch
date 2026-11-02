#pragma once

#include <QElapsedTimer>
#include <QFile>
#include <QImage>
#include <QObject>
#include <QPointF>
#include <QQmlEngine>
#include <QRecursiveMutex>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <vector>

struct s_cliprdr_client_context;
struct s_wClipboard;
struct cliprdr_file_context;
class QMimeData;
class RdpSession;

// One clipboard item as Perch sees it, from either side.
struct ClipItem {
    QString text, html;
    QImage image;
    QStringList files;   // absolute local paths (top-level entries)
    qint64 bytes = 0;    // total size of `files`, recursively
    int fileCount = 0;   // regular files under `files`, recursively
    bool concealed = false;
    quintptr origin = 0; // RdpClipboard that placed it on the Mac clipboard; 0 = the Mac itself
    bool isEmpty() const { return text.isEmpty() && html.isEmpty() && image.isNull() && files.isEmpty(); }
};

// In-memory history of recent clipboard items from both sides (this app run
// only; never written to disk). Shared by every session's history palette.
class ClipHistory : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
    Q_PROPERTY(bool reduceMotion READ reduceMotion CONSTANT)

public:
    static ClipHistory* instance();
    static ClipHistory* create(QQmlEngine*, QJSEngine*);

    void add(const ClipItem& item, bool fromServer, const QString& origin);
    ClipItem item(int id) const;
    QVariantList items() const;
    bool reduceMotion() const;

    // Preview fields shared by the capsule and the palette: kind, title, detail, thumb.
    static QVariantMap describe(const ClipItem& item);

signals:
    void changed();

private:
    explicit ClipHistory(QObject* parent = nullptr) : QObject(parent) {}
    struct Entry {
        int id;
        bool fromServer;
        QString origin;
        qint64 time;
        ClipItem item;
        QVariantMap preview;
    };
    std::deque<Entry> m_entries;
    int m_nextId = 1;
};

// Clipboard redirection (MS-RDPECLIP) for one session: text, HTML, images and
// files in both directions with delayed rendering. Lives on the GUI thread; the
// cliprdr callbacks run on the session's worker and hand results back with
// queued calls. Worker-side state is guarded by m_mx.
class RdpClipboard : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Owned by RdpSession")
    Q_PROPERTY(int mode READ mode WRITE setMode NOTIFY modeChanged)
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(bool unavailable READ unavailable NOTIFY availableChanged)
    Q_PROPERTY(QVariantMap activity READ activity NOTIFY activityChanged)
    Q_PROPERTY(bool hasServerItem READ hasServerItem NOTIFY activityChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY transferChanged)
    Q_PROPERTY(qreal progress READ progress NOTIFY transferChanged)
    Q_PROPERTY(QString transferText READ transferText NOTIFY transferChanged)
    Q_PROPERTY(QString transferDir READ transferDir NOTIFY transferChanged)

public:
    enum Mode { Both, ToServer, ToMac, Off };
    Q_ENUM(Mode)

    explicit RdpClipboard(RdpSession* session);
    ~RdpClipboard() override;

    int mode() const { return m_mode; }
    void setMode(int m);
    bool available() const { return m_available; }
    bool unavailable() const { return m_unavailable; }
    QVariantMap activity() const { return m_activity; }
    bool hasServerItem() const { return !m_lastRemote.isEmpty(); }
    bool busy() const { return m_busy; }
    qreal progress() const { return m_progress; }
    QString transferText() const { return m_transferText; }
    QString transferDir() const { return m_transferDir; }

    // --- GUI thread ---
    // Snapshot of the Mac clipboard. `record` adds it to the history (once per
    // change, not once per session).
    static ClipItem captureSystem(bool record);
    // The Mac clipboard changed: advertise it to the server (delayed rendering).
    void setLocal(const ClipItem& item);
    // Put `item` on the server clipboard and paste it (Ctrl+V), optionally
    // clicking at `remotePos` first. Emits pasteReady once the server has it.
    void pasteItem(const ClipItem& item, bool plain, const QPointF& remotePos, bool click);
    // Files / an image dropped on the remote view.
    bool dropMime(const QMimeData* mime, const QPointF& remotePos);
    void sessionConnected();

    Q_INVOKABLE void pasteHistory(int id, bool plain);
    Q_INVOKABLE void pastePlainText();
    Q_INVOKABLE void cancelTransfer();
    Q_INVOKABLE void download();
    Q_INVOKABLE void reveal();
    // Mime map for dragging the current server item out (text, or file URLs).
    Q_INVOKABLE QVariantMap dragData();

    // --- Worker thread ---
    void attach(s_cliprdr_client_context* c);
    void detach();
    void processPending();

signals:
    void modeChanged();
    void availableChanged();
    void activityChanged();
    void transferChanged();
    // The server now holds the item to paste; the view sends Ctrl+V.
    void pasteReady(const QPointF& remotePos, bool click);
    // A lazy (paste-in-Finder) download finished or failed.
    void lazySettled();

private:
    friend struct ClipCallbacks;

    struct RemoteEntry {
        QString rel; // sanitised relative path, '/'-separated
        bool dir = false;
        qint64 size = -1;
    };
    struct Fetch {
        quint32 id;
        int kind; // FetchKind
    };

    void post(std::function<void()> fn);
    void wake();
    void setActivity(QVariantMap a);
    void setTransfer(bool busy, qreal progress, const QString& text, const QString& dir);
    void offer(const ClipItem& item, bool paste, const QPointF& pos, bool click);
    void applyRemote(const ClipItem& item);
    void remoteFilesListed(std::vector<RemoteEntry> entries);
    void startDownload(std::vector<RemoteEntry> entries, bool lazy);
    QStringList provideLazy(quint64 gen);
    void notAvailable();

    // Worker side (m_mx held).
    void sendFormatList();
    void serializeFiles(const ClipItem& it, unsigned char** out, quint32* outLen);
    void parseFiles(const QByteArray& data);
    void planFetch();
    void requestNextFetch();
    void finishFetch();
    void dlNext();
    void dlRequest(quint32 flags, qint64 offset, quint32 size);
    void dlAbort(const QString& error);
    void dlCloseFile();

    RdpSession* m_session;

    // GUI-thread state.
    int m_mode = Both;
    std::atomic<int> m_modeA{Both}; // m_mode, readable from the worker
    bool m_available = false;
    bool m_filesOk = false;
    bool m_unavailable = false;
    bool m_warnedUnavailable = false;
    QVariantMap m_activity;
    int m_activitySeq = 0;
    bool m_busy = false;
    qreal m_progress = 0;
    QString m_transferText, m_transferDir;
    ClipItem m_lastRemote;
    ClipItem m_system; // last Mac clipboard snapshot
    std::vector<RemoteEntry> m_pendingFiles; // listed but not downloaded yet
    QStringList m_saved;                     // last downloaded top-level paths
    // Server files offered on the Mac pasteboard, fetched when another app pastes.
    enum LazyState { LazyIdle, LazyLoading, LazyDone };
    std::vector<RemoteEntry> m_lazyEntries;
    quint64 m_lazyGen = 0;
    LazyState m_lazyState = LazyIdle;
    QStringList m_lazyPaths;
    QString m_lazyRoot;
    QTimer m_availTimer;
    QTimer m_stall; // ends a transfer the server silently abandoned

    // Shared with the worker (m_mx).
    mutable QRecursiveMutex m_mx;
    s_cliprdr_client_context* m_cliprdr = nullptr;
    cliprdr_file_context* m_file = nullptr;
    s_wClipboard* m_wclip = nullptr;
    void* m_origFileRequest = nullptr; // FreeRDP's ServerFileContentsRequest
    quint32 m_remoteFlags = 0;
    bool m_ready = false;          // MonitorReady seen
    ClipItem m_offer;              // what we advertise to the server
    bool m_offerDirty = false;
    bool m_pasteArmed = false;     // send pasteReady on the next format-list ack
    bool m_pasteQueued = false;    // ... once the list carrying it went out
    QPointF m_pastePos;
    bool m_pasteClick = false;
    std::vector<std::pair<quint32, QString>> m_serverFormats;
    std::deque<Fetch> m_fetch;
    bool m_awaiting = false;       // a format data request is outstanding
    bool m_refetch = false;        // the server list changed while awaiting
    ClipItem m_incoming;
    std::vector<RemoteEntry> m_incomingFiles;

    // Remote -> local download (worker).
    struct Download {
        bool active = false;
        bool lazy = false; // fetched for a paste: hand the paths over, don't touch the clipboard
        std::vector<RemoteEntry> entries;
        QString root;
        size_t index = 0;
        qint64 offset = 0;
        qint64 done = 0, total = 0;
        bool sizing = false;
        quint32 streamId = 0;
        std::unique_ptr<QFile> out;
        QElapsedTimer tick;
    } m_dl;
    bool m_dlStart = false;
    std::atomic<bool> m_cancel{false};

    // Local -> remote upload progress (worker).
    qint64 m_upTotal = 0, m_upSent = 0;
    int m_upCount = 0;
    bool m_upActive = false;
    QElapsedTimer m_upTick;
};
