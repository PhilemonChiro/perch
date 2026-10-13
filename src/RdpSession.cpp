#include "RdpSession.h"

#include <QClipboard>
#include <QDir>
#include <QGuiApplication>
#include <QPointF>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <winpr/user.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

struct RelayContext {
    rdpClientContext common;
    RdpSession* self;
};

RdpSession* selfOf(rdpContext* ctx)
{
    return reinterpret_cast<RelayContext*>(ctx)->self;
}

bool isAuthError(UINT32 e)
{
    switch (e) {
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
    case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
    case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
    case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        return true;
    default:
        return false;
    }
}

} // namespace

// Static trampolines from FreeRDP's C callbacks into the session object.
struct RdpCallbacks {
    static BOOL clientNew(freerdp* instance, rdpContext*)
    {
        instance->PreConnect = preConnect;
        instance->PostConnect = postConnect;
        instance->PostDisconnect = postDisconnect;
        instance->AuthenticateEx = authenticate;
        instance->VerifyCertificateEx = verifyCertificate;
        instance->VerifyChangedCertificateEx = verifyChangedCertificate;
        instance->LoadChannels = freerdp_client_load_channels;
        return TRUE;
    }

    static BOOL preConnect(freerdp* instance)
    {
        rdpContext* ctx = instance->context;
        PubSub_SubscribeChannelConnected(ctx->pubSub, channelConnected);
        PubSub_SubscribeChannelDisconnected(ctx->pubSub, channelDisconnected);
        RdpSession* self = selfOf(ctx);
        self->post([self] { self->setStatus(RdpSession::tr("Negotiating a secure connection…"), 1); });
        return TRUE;
    }

    static BOOL postConnect(freerdp* instance)
    {
        return selfOf(instance->context)->onPostConnect() ? TRUE : FALSE;
    }

    static void postDisconnect(freerdp* instance)
    {
        rdpContext* ctx = instance->context;
        PubSub_UnsubscribeChannelConnected(ctx->pubSub, channelConnected);
        PubSub_UnsubscribeChannelDisconnected(ctx->pubSub, channelDisconnected);
        selfOf(ctx)->onPostDisconnect();
    }

    // Credentials are collected by the UI before connecting; if the server
    // still asks, fail so the UI can prompt with an error.
    static BOOL authenticate(freerdp* instance, char** username, char** password, char**,
                             rdp_auth_reason)
    {
        const bool ok = username && *username && **username && password && *password;
        if (!ok)
            // Reaching the auth stage proves the host is reachable; record that so a
            // missing-credentials abort isn't misreported as a connectivity failure.
            selfOf(instance->context)->m_credentialsNeeded = true;
        return ok ? TRUE : FALSE;
    }

    static DWORD verifyCertificate(freerdp* instance, const char* host, UINT16 port, const char*,
                                   const char* subject, const char* issuer, const char* fingerprint,
                                   DWORD)
    {
        return selfOf(instance->context)
            ->onVerifyCertificate(host, port, subject, issuer, fingerprint, false, nullptr);
    }

    static DWORD verifyChangedCertificate(freerdp* instance, const char* host, UINT16 port,
                                          const char*, const char* subject, const char* issuer,
                                          const char* fingerprint, const char*, const char*,
                                          const char* oldFingerprint, DWORD)
    {
        return selfOf(instance->context)
            ->onVerifyCertificate(host, port, subject, issuer, fingerprint, true, oldFingerprint);
    }

    static BOOL beginPaint(rdpContext* ctx)
    {
        HGDI_WND hwnd = ctx->gdi->primary->hdc->hwnd;
        hwnd->invalid->null = TRUE;
        hwnd->ninvalid = 0;
        return TRUE;
    }

    static BOOL endPaint(rdpContext* ctx)
    {
        selfOf(ctx)->onEndPaint();
        return TRUE;
    }

    static BOOL desktopResize(rdpContext* ctx)
    {
        return selfOf(ctx)->onDesktopResize() ? TRUE : FALSE;
    }

    static void channelConnected(void* context, const ChannelConnectedEventArgs* e)
    {
        auto* ctx = static_cast<rdpContext*>(context);
        if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
            selfOf(ctx)->onClipboardConnected(static_cast<CliprdrClientContext*>(e->pInterface));
        else if (std::strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
            selfOf(ctx)->onDispConnected(static_cast<DispClientContext*>(e->pInterface));
        else
            freerdp_client_OnChannelConnectedEventHandler(context, e);
    }

    static void channelDisconnected(void* context, const ChannelDisconnectedEventArgs* e)
    {
        auto* ctx = static_cast<rdpContext*>(context);
        RdpSession* self = selfOf(ctx);
        if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
            self->m_cliprdr = nullptr;
        else if (std::strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
            self->m_disp = nullptr;
            self->m_dispReady = false;
        } else
            freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }

    // --- Display control ---
    static UINT dispCaps(DispClientContext* disp, UINT32, UINT32, UINT32)
    {
        auto* self = static_cast<RdpSession*>(disp->custom);
        self->m_dispReady = true;
        {
            QMutexLocker lock(&self->m_pendingMutex);
            self->m_pendingResize = self->m_viewport;
        }
        SetEvent(self->m_wakeEvent);
        return CHANNEL_RC_OK;
    }

    // --- Clipboard (text) ---
    static RdpSession* clipSelf(CliprdrClientContext* c) { return static_cast<RdpSession*>(c->custom); }

    static UINT clipMonitorReady(CliprdrClientContext* c, const CLIPRDR_MONITOR_READY*)
    {
        CLIPRDR_GENERAL_CAPABILITY_SET general{};
        general.capabilitySetType = CB_CAPSTYPE_GENERAL;
        general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
        general.version = CB_CAPS_VERSION_2;
        general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
        CLIPRDR_CAPABILITIES caps{};
        caps.cCapabilitiesSets = 1;
        caps.capabilitySets = reinterpret_cast<CLIPRDR_CAPABILITY_SET*>(&general);
        const UINT rc = c->ClientCapabilities(c, &caps);
        if (rc != CHANNEL_RC_OK)
            return rc;
        clipSelf(c)->sendClipboardFormatList();
        return CHANNEL_RC_OK;
    }

    static UINT clipServerCaps(CliprdrClientContext*, const CLIPRDR_CAPABILITIES*) { return CHANNEL_RC_OK; }

    static UINT clipServerFormatList(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST* list)
    {
        CLIPRDR_FORMAT_LIST_RESPONSE resp{};
        resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
        resp.common.msgFlags = CB_RESPONSE_OK;
        const UINT rc = c->ClientFormatListResponse(c, &resp);
        if (rc != CHANNEL_RC_OK)
            return rc;

        UINT32 wanted = 0;
        for (UINT32 i = 0; i < list->numFormats; ++i) {
            if (list->formats[i].formatId == CF_UNICODETEXT) {
                wanted = CF_UNICODETEXT;
                break;
            }
            if (list->formats[i].formatId == CF_TEXT)
                wanted = CF_TEXT;
        }
        if (!wanted)
            return CHANNEL_RC_OK;
        clipSelf(c)->m_requestedFormat = wanted;
        CLIPRDR_FORMAT_DATA_REQUEST req{};
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = wanted;
        return c->ClientFormatDataRequest(c, &req);
    }

    static UINT clipServerFormatListResponse(CliprdrClientContext*, const CLIPRDR_FORMAT_LIST_RESPONSE*)
    {
        return CHANNEL_RC_OK;
    }

    static UINT clipServerFormatDataRequest(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* req)
    {
        CLIPRDR_FORMAT_DATA_RESPONSE resp{};
        resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
        QByteArray data;
        if (req->requestedFormatId == CF_UNICODETEXT) {
            data = clipSelf(c)->localClipboardUtf16();
            resp.common.msgFlags = CB_RESPONSE_OK;
            resp.common.dataLen = UINT32(data.size());
            resp.requestedFormatData = reinterpret_cast<const BYTE*>(data.constData());
        } else {
            resp.common.msgFlags = CB_RESPONSE_FAIL;
        }
        return c->ClientFormatDataResponse(c, &resp);
    }

    static UINT clipServerFormatDataResponse(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_RESPONSE* resp)
    {
        if (!(resp->common.msgFlags & CB_RESPONSE_OK) || !resp->requestedFormatData)
            return CHANNEL_RC_OK;
        RdpSession* self = clipSelf(c);
        self->applyRemoteClipboard(
            QByteArray(reinterpret_cast<const char*>(resp->requestedFormatData), int(resp->common.dataLen)),
            self->m_requestedFormat == CF_UNICODETEXT);
        return CHANNEL_RC_OK;
    }
};

RdpSession::RdpSession(const QString& hostId, const QString& title, const QString& host, int port,
                       const QString& username, const QString& domain, QObject* parent)
    : QObject(parent)
    , m_hostId(hostId)
    , m_title(title.isEmpty() ? host : title)
    , m_host(host)
    , m_port(port > 0 ? port : 3389)
    , m_username(username)
    , m_domain(domain)
{
    m_wakeEvent = CreateEventA(nullptr, TRUE, FALSE, nullptr);
}

RdpSession::~RdpSession()
{
    stopWorker();
    if (m_wakeEvent)
        CloseHandle(m_wakeEvent);
}

void RdpSession::post(std::function<void()> fn)
{
    QMetaObject::invokeMethod(this, std::move(fn), Qt::QueuedConnection);
}

void RdpSession::setState(State s)
{
    if (m_state == s)
        return;
    m_state = s;
    emit stateChanged();
}

void RdpSession::setStatus(const QString& text, int stage)
{
    m_statusText = text;
    m_stage = stage;
    emit statusChanged();
}

void RdpSession::startWithPassword(const QString& password)
{
    m_password = password;
    m_remember = false;
    start();
}

void RdpSession::shareFolder(const QString& path)
{
    if (m_sharedFolder == path)
        return;
    m_sharedFolder = path;
    emit sharedFolderChanged();
    // Reconnect to renegotiate redirection; reuse the in-memory credentials so
    // the user isn't prompted again. If we somehow lack them, fall back to a prompt.
    if (!m_username.isEmpty() && !m_password.isEmpty())
        start();
    else
        requestCredentials(QString());
}

void RdpSession::requestCredentials(const QString& error)
{
    m_errorText = error;
    emit errorTextChanged();
    setState(NeedsCredentials);
}

void RdpSession::signIn(const QString& username, const QString& password, const QString& domain,
                        bool remember)
{
    m_username = username;
    m_domain = domain;
    m_password = password;
    m_remember = remember;
    emit credentialsChanged();
    start();
}

void RdpSession::reconnect()
{
    if (m_username.isEmpty() || m_password.isEmpty()) {
        stopWorker();
        requestCredentials(QString());
        return;
    }
    start();
}

void RdpSession::disconnect()
{
    m_stop = true;
    {
        QMutexLocker lock(&m_contextMutex);
        if (m_context)
            freerdp_abort_connect_context(m_context);
    }
    {
        QMutexLocker lock(&m_certMutex);
        m_certVerdict = 0;
        m_certCond.wakeAll();
    }
    if (m_wakeEvent)
        SetEvent(m_wakeEvent);
}

void RdpSession::answerCertificate(int verdict)
{
    m_certificate.clear();
    emit certificateChanged();
    QMutexLocker lock(&m_certMutex);
    m_certVerdict = qBound(0, verdict, 2);
    m_certCond.wakeAll();
}

void RdpSession::start()
{
    stopWorker();
    m_stop = false;
    m_errorText.clear();
    emit errorTextChanged();
    m_certificate.clear();
    emit certificateChanged();
    if (m_hasFrame) {
        m_hasFrame = false;
        emit hasFrameChanged();
    }
    setStatus(tr("Connecting to %1…").arg(m_host), 0);
    setState(Connecting);
    m_thread = std::thread([this] { run(); });
}

void RdpSession::stopWorker()
{
    if (!m_thread.joinable())
        return;
    disconnect();
    m_thread.join();
}

void RdpSession::run()
{
    RDP_CLIENT_ENTRY_POINTS ep{};
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size = sizeof(ep);
    ep.ContextSize = sizeof(RelayContext);
    ep.ClientNew = RdpCallbacks::clientNew;

    rdpContext* ctx = freerdp_client_context_new(&ep);
    if (!ctx) {
        post([this] { m_errorText = tr("Couldn’t initialise the RDP engine."); emit errorTextChanged(); setState(Failed); });
        return;
    }
    reinterpret_cast<RelayContext*>(ctx)->self = this;

    QSize size;
    int scale;
    {
        QMutexLocker lock(&m_pendingMutex);
        size = m_viewport;
        scale = m_scale;
    }

    const QString hostArg = m_host.contains(':') ? '[' + m_host + ']' : m_host;
    std::vector<std::string> args = {
        "relay",
        ("/v:" + hostArg).toStdString(),
        "/port:" + std::to_string(m_port),
        ("/u:" + m_username).toStdString(),
        "/w:" + std::to_string(size.width()),
        "/h:" + std::to_string(size.height()),
        "/bpp:32",
        "/gfx",
        "+clipboard",
        "/dynamic-resolution",
        "/network:auto",
        "+auto-reconnect",
    };
    if (!m_domain.isEmpty())
        args.push_back(("/d:" + m_domain).toStdString());
    if (!m_sharedFolder.isEmpty()) {
        // Redirect a local folder as a drive; it shows up under "This PC" in the
        // remote session. Label it with the folder's name, falling back to "Relay".
        QString label = QDir(m_sharedFolder).dirName();
        if (label.isEmpty())
            label = QStringLiteral("Relay");
        label.replace(',', ' '); // commas separate the /drive: fields
        args.push_back(("/drive:" + label + "," + m_sharedFolder).toStdString());
    }
    std::vector<char*> argv;
    for (std::string& a : args)
        argv.push_back(a.data());

    rdpSettings* settings = ctx->settings;
    const int parsed = freerdp_client_settings_parse_command_line(settings, int(argv.size()), argv.data(), FALSE);
    if (parsed < 0) {
        freerdp_client_context_free(ctx);
        post([this] { m_errorText = tr("Invalid connection settings."); emit errorTextChanged(); setState(Failed); });
        return;
    }
    // Set directly rather than via /p: so the secret never sits in argv.
    freerdp_settings_set_string(settings, FreeRDP_Password, m_password.toUtf8().constData());
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, UINT32(scale));
    freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor,
                                scale >= 180 ? 180 : scale >= 140 ? 140 : 100);

    {
        QMutexLocker lock(&m_contextMutex);
        m_context = ctx;
    }
    ResetEvent(m_wakeEvent);
    m_credentialsNeeded = false;
    freerdp_client_start(ctx);

    freerdp* instance = ctx->instance;
    const bool connected = !m_stop && freerdp_connect(instance);

    if (!connected) {
        const UINT32 err = freerdp_get_last_error(ctx);
        const bool aborted = m_stop;
        const bool hadPassword = !m_password.isEmpty();
        const bool credentialsNeeded = m_credentialsNeeded;
        post([this, err, aborted, hadPassword, credentialsNeeded] {
            if (aborted) {
                setStatus(tr("Connection cancelled."), 0);
                setState(Disconnected);
            } else if (isAuthError(err) || credentialsNeeded
                       || (err == FREERDP_ERROR_CONNECT_CANCELLED && !hadPassword)) {
                requestCredentials(hadPassword ? tr("The username or password is incorrect.")
                                               : QString());
            } else if (err == FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED
                       || err == FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE) {
                requestCredentials(tr("Your password has expired. Change it on the server, then sign in again."));
            } else {
                QString msg;
                if (err == FREERDP_ERROR_DNS_NAME_NOT_FOUND)
                    msg = tr("Couldn’t find a host named “%1”.").arg(m_host);
                else if (err == FREERDP_ERROR_CONNECT_FAILED || err == FREERDP_ERROR_CONNECT_TRANSPORT_FAILED)
                    msg = tr("Couldn’t reach %1:%2. Check the address and that Remote Desktop is enabled.")
                              .arg(m_host).arg(m_port);
                else if (err == FREERDP_ERROR_TLS_CONNECT_FAILED)
                    msg = tr("The secure connection couldn’t be established (certificate not trusted or TLS failure).");
                else
                    msg = QString::fromUtf8(freerdp_get_last_error_string(err));
                m_errorText = msg;
                emit errorTextChanged();
                setState(Failed);
            }
        });
    } else {
        const QString user = m_username, domain = m_domain, password = m_password;
        const bool remember = m_remember;
        post([this, user, domain, password, remember] {
            emit connectedWithCredentials(user, domain, password, remember);
        });

        while (!m_stop && !freerdp_shall_disconnect_context(ctx)) {
            HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {};
            DWORD n = freerdp_get_event_handles(ctx, handles, ARRAYSIZE(handles) - 1);
            if (n == 0)
                break;
            handles[n++] = m_wakeEvent;
            if (WaitForMultipleObjects(n, handles, FALSE, 100) == WAIT_FAILED)
                break;
            if (!freerdp_check_event_handles(ctx)) {
                if (!m_stop && client_auto_reconnect_ex(instance, nullptr))
                    continue;
                break;
            }
            if (WaitForSingleObject(m_wakeEvent, 0) == WAIT_OBJECT_0) {
                ResetEvent(m_wakeEvent);
                processPending();
            }
        }

        const UINT32 info = freerdp_error_info(instance);
        const bool byUser = m_stop;
        post([this, info, byUser] {
            QString msg;
            if (byUser)
                msg = tr("You disconnected from %1.").arg(m_title);
            else if (info == 0 || info == ERRINFO_LOGOFF_BY_USER || info == ERRINFO_RPC_INITIATED_LOGOFF
                     || info == ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER)
                msg = tr("The remote session ended.");
            else
                msg = QString::fromUtf8(freerdp_get_error_info_string(info));
            m_errorText.clear();
            emit errorTextChanged();
            setStatus(msg, 0);
            setState(Disconnected);
        });
    }

    {
        QMutexLocker lock(&m_contextMutex);
        m_live = false;
    }
    freerdp_disconnect(instance);
    freerdp_client_stop(ctx);
    {
        QMutexLocker lock(&m_contextMutex);
        m_context = nullptr;
    }
    freerdp_client_context_free(ctx);
}

bool RdpSession::onPostConnect()
{
    freerdp* instance = m_context->instance;
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
        return false;
    rdpUpdate* update = m_context->update;
    update->BeginPaint = RdpCallbacks::beginPaint;
    update->EndPaint = RdpCallbacks::endPaint;
    update->DesktopResize = RdpCallbacks::desktopResize;

    const rdpGdi* gdi = m_context->gdi;
    const QSize size(int(gdi->width), int(gdi->height));
    {
        QMutexLocker lock(&m_frameMutex);
        m_frame = QImage(size, QImage::Format_RGB32);
        m_frame.fill(Qt::black);
    }
    {
        QMutexLocker lock(&m_contextMutex);
        m_live = true;
    }
    post([this, size] {
        m_remoteSize = size;
        emit remoteSizeChanged();
        setStatus(tr("Starting the desktop…"), 3);
        setState(Connected);
    });
    return true;
}

void RdpSession::onPostDisconnect()
{
    gdi_free(m_context->instance);
    m_cliprdr = nullptr;
    m_disp = nullptr;
    m_dispReady = false;
}

bool RdpSession::onDesktopResize()
{
    const rdpSettings* s = m_context->settings;
    const UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
    const UINT32 h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
    if (!gdi_resize(m_context->gdi, w, h))
        return false;
    const QSize size{int(w), int(h)};
    {
        QMutexLocker lock(&m_frameMutex);
        m_frame = QImage(size, QImage::Format_RGB32);
        m_frame.fill(Qt::black);
    }
    post([this, size] { m_remoteSize = size; emit remoteSizeChanged(); });
    return true;
}

void RdpSession::onEndPaint()
{
    const rdpGdi* gdi = m_context->gdi;
    if (gdi->suppressOutput)
        return;
    const HGDI_RGN inv = gdi->primary->hdc->hwnd->invalid;
    if (inv->null)
        return;

    const QSize size(int(gdi->width), int(gdi->height));
    bool resized = false;
    {
        QMutexLocker lock(&m_frameMutex);
        if (m_frame.size() != size) {
            // The graphics pipeline can reset the surface without DesktopResize.
            m_frame = QImage(size, QImage::Format_RGB32);
            resized = true;
        }
        const QRect r = resized ? QRect(QPoint(0, 0), size)
                                : QRect(inv->x, inv->y, inv->w, inv->h).intersected(QRect(QPoint(0, 0), size));
        const BYTE* src = gdi->primary_buffer;
        for (int y = r.top(); y <= r.bottom(); ++y)
            std::memcpy(m_frame.scanLine(y) + r.x() * 4, src + size_t(y) * gdi->stride + r.x() * 4,
                        size_t(r.width()) * 4);
    }
    if (resized)
        post([this, size] { m_remoteSize = size; emit remoteSizeChanged(); });
    if (!m_framePending.exchange(true)) {
        post([this] {
            m_framePending = false;
            if (!m_hasFrame) {
                m_hasFrame = true;
                emit hasFrameChanged();
            }
            emit frameUpdated();
        });
    }
}

unsigned long RdpSession::onVerifyCertificate(const char* host, quint16 port, const char* subject,
                                              const char* issuer, const char* fingerprint,
                                              bool changed, const char* oldFingerprint)
{
    QVariantMap cert{
        {"host", QString::fromUtf8(host) + (port != 3389 ? ":" + QString::number(port) : QString())},
        {"subject", QString::fromUtf8(subject ? subject : "")},
        {"issuer", QString::fromUtf8(issuer ? issuer : "")},
        {"fingerprint", QString::fromUtf8(fingerprint ? fingerprint : "")},
        {"changed", changed},
        {"oldFingerprint", QString::fromUtf8(oldFingerprint ? oldFingerprint : "")},
    };
    {
        QMutexLocker lock(&m_certMutex);
        m_certVerdict = -1;
    }
    post([this, cert] {
        m_certificate = cert;
        emit certificateChanged();
        setStatus(tr("Verifying the server’s identity…"), 1);
        setState(VerifyingCertificate);
    });

    int verdict;
    {
        QMutexLocker lock(&m_certMutex);
        while (m_certVerdict < 0 && !m_stop)
            m_certCond.wait(&m_certMutex, 200);
        verdict = m_stop ? 0 : m_certVerdict;
    }
    post([this, verdict] {
        if (verdict == 0)
            return;
        setStatus(tr("Signing in…"), 2);
        setState(Connecting);
    });
    return DWORD(verdict);
}

void RdpSession::onClipboardConnected(CliprdrClientContext* c)
{
    m_cliprdr = c;
    c->custom = this;
    c->MonitorReady = RdpCallbacks::clipMonitorReady;
    c->ServerCapabilities = RdpCallbacks::clipServerCaps;
    c->ServerFormatList = RdpCallbacks::clipServerFormatList;
    c->ServerFormatListResponse = RdpCallbacks::clipServerFormatListResponse;
    c->ServerFormatDataRequest = RdpCallbacks::clipServerFormatDataRequest;
    c->ServerFormatDataResponse = RdpCallbacks::clipServerFormatDataResponse;
}

void RdpSession::onDispConnected(DispClientContext* disp)
{
    m_disp = disp;
    disp->custom = this;
    disp->DisplayControlCaps = RdpCallbacks::dispCaps;
}

void RdpSession::processPending()
{
    QSize resize;
    bool clipboard;
    {
        QMutexLocker lock(&m_pendingMutex);
        resize = m_pendingResize;
        m_pendingResize = QSize();
        clipboard = m_pendingClipboard;
        m_pendingClipboard = false;
    }
    if (resize.isValid())
        sendMonitorLayout(resize);
    if (clipboard)
        sendClipboardFormatList();
}

void RdpSession::sendMonitorLayout(const QSize& size)
{
    if (!m_disp || !m_dispReady)
        return;
    const rdpGdi* gdi = m_context->gdi;
    if (gdi && int(gdi->width) == size.width() && int(gdi->height) == size.height())
        return;
    int scale;
    {
        QMutexLocker lock(&m_pendingMutex);
        scale = m_scale;
    }
    DISPLAY_CONTROL_MONITOR_LAYOUT layout{};
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = UINT32(size.width());
    layout.Height = UINT32(size.height());
    layout.Orientation = 0; // landscape
    layout.DesktopScaleFactor = UINT32(scale);
    layout.DeviceScaleFactor = scale >= 180 ? 180 : scale >= 140 ? 140 : 100;
    (void)m_disp->SendMonitorLayout(m_disp, 1, &layout);
}

void RdpSession::sendClipboardFormatList()
{
    if (!m_cliprdr)
        return;
    bool hasText;
    {
        QMutexLocker lock(&m_pendingMutex);
        hasText = !m_localClipboard.isEmpty();
    }
    CLIPRDR_FORMAT format{CF_UNICODETEXT, nullptr};
    CLIPRDR_FORMAT_LIST list{};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = hasText ? 1 : 0;
    list.formats = hasText ? &format : nullptr;
    (void)m_cliprdr->ClientFormatList(m_cliprdr, &list);
}

QByteArray RdpSession::localClipboardUtf16() const
{
    QString text;
    {
        QMutexLocker lock(&m_pendingMutex);
        text = m_localClipboard;
    }
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n")).replace('\n', QStringLiteral("\r\n"));
    QByteArray out(reinterpret_cast<const char*>(text.utf16()), text.size() * 2);
    out.append(2, '\0');
    return out;
}

void RdpSession::applyRemoteClipboard(const QByteArray& data, bool unicode)
{
    QString text = unicode ? QString::fromUtf16(reinterpret_cast<const char16_t*>(data.constData()), data.size() / 2)
                           : QString::fromLatin1(data);
    while (text.endsWith(QChar(0)))
        text.chop(1);
#ifndef Q_OS_WIN
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
#endif
    post([this, text] {
        m_lastRemoteClipboard = text;
        QGuiApplication::clipboard()->setText(text);
    });
}

void RdpSession::setLocalClipboard(const QString& text)
{
    // Don't bounce the server's own clipboard back to it.
    const bool echo = text == m_lastRemoteClipboard;
    {
        QMutexLocker lock(&m_pendingMutex);
        m_localClipboard = text;
        if (!echo)
            m_pendingClipboard = true;
    }
    if (!echo && m_wakeEvent)
        SetEvent(m_wakeEvent);
}

QImage RdpSession::frame() const
{
    QMutexLocker lock(&m_frameMutex);
    return m_frame;
}

void RdpSession::setViewport(const QSize& physical, qreal dpr)
{
    const QSize size(qBound(200, physical.width() & ~1, 8192), qBound(200, physical.height(), 8192));
    {
        QMutexLocker lock(&m_pendingMutex);
        m_viewport = size;
        m_scale = qBound(100, int(dpr * 100 + 0.5), 500);
        if (m_dispReady)
            m_pendingResize = size;
    }
    if (m_dispReady && m_wakeEvent)
        SetEvent(m_wakeEvent);
}

void RdpSession::sendMouse(quint16 flags, const QPointF& pos)
{
    QMutexLocker lock(&m_contextMutex);
    if (!m_live || !m_context)
        return;
    freerdp_input_send_mouse_event(m_context->input, flags, quint16(qMax(0.0, pos.x())),
                                   quint16(qMax(0.0, pos.y())));
}

void RdpSession::sendKey(bool down, bool repeat, quint32 rdpScancode)
{
    QMutexLocker lock(&m_contextMutex);
    if (!m_live || !m_context)
        return;
    freerdp_input_send_keyboard_event_ex(m_context->input, down, repeat, rdpScancode);
}
