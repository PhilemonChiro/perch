#include "RdpClipboard.h"

#include "MacPasteboard.h"
#include "RdpSession.h"

#include <QBuffer>
#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLocale>
#include <QMimeData>
#include <QPointer>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTextDocumentFragment>
#include <QUrl>
#include <QUuid>
#include <QtEndian>

#include <freerdp/client/cliprdr.h>
#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/clipboard.h>
#include <winpr/shell.h>
#include <winpr/user.h>

#include <cstring>

namespace {

// Registered formats we advertise use client-chosen ids in the 0xC000+ range;
// the server maps them by name.
constexpr quint32 kFmtFiles = 0xC0F1;
constexpr quint32 kFmtPng = 0xC0F2;
constexpr quint32 kFmtHtml = 0xC0F3;
const char kNameFiles[] = "FileGroupDescriptorW";
const char kNamePng[] = "PNG";
const char kNameHtml[] = "HTML Format";

// Marks Mac clipboard contents Perch placed there from a server, so the change
// notification is not echoed back to the same server or recorded as a Mac copy.
const char kOriginMime[] = "application/x-perch-origin";

constexpr int kHistoryMax = 20;
constexpr quint32 kChunk = 1024 * 1024;
constexpr int kTickMs = 80;

enum FetchKind { KFiles, KPng, KDib, KHtml, KUtf16, KAnsi };

bool allowsToServer(int m) { return m == RdpClipboard::Both || m == RdpClipboard::ToServer; }
bool allowsToMac(int m) { return m == RdpClipboard::Both || m == RdpClipboard::ToMac; }

// Recursive size and file count of local paths (bounded so a huge tree can't stall the UI).
void measure(const QStringList& paths, qint64* bytes, int* count)
{
    *bytes = 0;
    *count = 0;
    int budget = 50000;
    for (const QString& p : paths) {
        const QFileInfo fi(p);
        if (!fi.isDir()) {
            *bytes += fi.size();
            ++*count;
            continue;
        }
        QDirIterator it(p, QDir::Files | QDir::Hidden | QDir::NoSymLinks, QDirIterator::Subdirectories);
        while (it.hasNext() && --budget > 0) {
            it.next();
            *bytes += it.fileInfo().size();
            ++*count;
        }
    }
}

// A server-supplied relative path, made safe to join under a local folder.
QString sanitizeRel(const QString& name)
{
    static const QRegularExpression sep(QStringLiteral("[\\\\/]"));
    QStringList out;
    for (QString part : name.split(sep, Qt::SkipEmptyParts)) {
        part = part.trimmed();
        if (part.isEmpty() || part == QLatin1String(".") || part == QLatin1String(".."))
            continue;
        part.replace(':', '_');
        out << part;
    }
    return out.join('/');
}

QByteArray utf16Crlf(QString text)
{
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n")).replace('\n', QStringLiteral("\r\n"));
    QByteArray out(reinterpret_cast<const char*>(text.utf16()), text.size() * 2);
    out.append(2, '\0');
    return out;
}

QString fromWire(const QByteArray& data, bool unicode)
{
    QString text = unicode ? QString::fromUtf16(reinterpret_cast<const char16_t*>(data.constData()), data.size() / 2)
                           : QString::fromLatin1(data);
    const int nul = int(text.indexOf(QChar(0)));
    if (nul >= 0)
        text.truncate(nul);
#ifndef Q_OS_WIN
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
#endif
    return text;
}

// CF_DIB / CF_DIBV5 are BMP files without the 14-byte file header.
QByteArray encodeDib(const QImage& img)
{
    QByteArray bmp;
    QBuffer buf(&bmp);
    buf.open(QIODevice::WriteOnly);
    if (!img.convertToFormat(QImage::Format_RGB32).save(&buf, "BMP") || bmp.size() <= 14)
        return {};
    return bmp.mid(14);
}

QImage decodeDib(const QByteArray& dib)
{
    if (dib.size() < 40)
        return {};
    auto u32 = [&](int at) { quint32 v; std::memcpy(&v, dib.constData() + at, 4); return qFromLittleEndian(v); };
    auto u16 = [&](int at) { quint16 v; std::memcpy(&v, dib.constData() + at, 2); return qFromLittleEndian(v); };
    const quint32 headerSize = u32(0);
    const quint16 bitCount = u16(14);
    const quint32 compression = u32(16);
    quint32 colors = u32(32);
    if (!colors && bitCount <= 8)
        colors = 1u << bitCount;
    quint32 offset = 14 + headerSize + colors * 4;
    if (headerSize == 40 && compression == 3 /* BI_BITFIELDS */)
        offset += 12;
    QByteArray bmp("BM");
    bmp.resize(14);
    const quint32 fileSize = qToLittleEndian(quint32(14 + dib.size()));
    const quint32 off = qToLittleEndian(offset);
    std::memcpy(bmp.data() + 2, &fileSize, 4);
    std::memset(bmp.data() + 6, 0, 4);
    std::memcpy(bmp.data() + 10, &off, 4);
    bmp += dib;
    return QImage::fromData(bmp, "BMP");
}

// Windows "HTML Format": a header of byte offsets into the UTF-8 payload.
QByteArray encodeCfHtml(QString html)
{
    static const QRegularExpression body(QStringLiteral("<body[^>]*>(.*)</body>"),
                                         QRegularExpression::CaseInsensitiveOption
                                             | QRegularExpression::DotMatchesEverythingOption);
    if (const auto m = body.match(html); m.hasMatch())
        html = m.captured(1);
    const QByteArray pre = "<html><body>\r\n<!--StartFragment-->";
    const QByteArray frag = html.toUtf8();
    const QByteArray post = "<!--EndFragment-->\r\n</body></html>";
    auto header = [](int a, int b, int c, int d) {
        auto n = [](int v) { return QByteArray::number(v).rightJustified(10, '0'); };
        return "Version:0.9\r\nStartHTML:" + n(a) + "\r\nEndHTML:" + n(b) + "\r\nStartFragment:" + n(c)
               + "\r\nEndFragment:" + n(d) + "\r\n";
    };
    const int headerLen = int(header(0, 0, 0, 0).size());
    const int startHtml = headerLen;
    const int startFrag = startHtml + int(pre.size());
    const int endFrag = startFrag + int(frag.size());
    const int endHtml = endFrag + int(post.size());
    QByteArray out = header(startHtml, endHtml, startFrag, endFrag);
    out += pre + frag + post;
    out.append('\0');
    return out;
}

QString decodeCfHtml(QByteArray data)
{
    if (const int nul = int(data.indexOf('\0')); nul >= 0)
        data.truncate(nul);
    auto field = [&](const char* key) -> int {
        const int at = int(data.indexOf(key));
        if (at < 0)
            return -1;
        return data.mid(at + int(std::strlen(key)), 10).trimmed().toInt();
    };
    int s = field("StartFragment:"), e = field("EndFragment:");
    if (s < 0 || e <= s || e > data.size()) {
        s = field("StartHTML:");
        e = field("EndHTML:");
    }
    if (s < 0 || e <= s || e > data.size()) {
        s = int(data.indexOf('<'));
        e = int(data.size());
    }
    return s < 0 ? QString() : QString::fromUtf8(data.mid(s, e - s));
}

QString thumbUrl(const QImage& img)
{
    if (img.isNull())
        return {};
    QByteArray png;
    QBuffer buf(&png);
    buf.open(QIODevice::WriteOnly);
    img.scaled(240, 240, Qt::KeepAspectRatio, Qt::SmoothTransformation).save(&buf, "PNG");
    return QStringLiteral("data:image/png;base64,") + QString::fromLatin1(png.toBase64());
}

QString plainOf(const ClipItem& it)
{
    if (!it.text.isEmpty())
        return it.text;
    if (!it.html.isEmpty())
        return QTextDocumentFragment::fromHtml(it.html).toPlainText();
    QStringList names;
    for (const QString& f : it.files)
        names << QFileInfo(f).fileName();
    return names.join('\n');
}

} // namespace

// ---------------------------------------------------------------- history

ClipHistory* ClipHistory::instance()
{
    static ClipHistory* h = new ClipHistory;
    return h;
}

ClipHistory* ClipHistory::create(QQmlEngine*, QJSEngine*)
{
    QQmlEngine::setObjectOwnership(instance(), QQmlEngine::CppOwnership);
    return instance();
}

bool ClipHistory::reduceMotion() const
{
    return MacPasteboard::reduceMotion();
}

QVariantMap ClipHistory::describe(const ClipItem& it)
{
    QVariantMap m;
    if (!it.files.isEmpty()) {
        const int n = qMax(it.fileCount, int(it.files.size()));
        m["kind"] = "files";
        m["title"] = it.files.size() == 1 ? QFileInfo(it.files.first()).fileName() : tr("%n files", nullptr, n);
        m["detail"] = it.bytes > 0 ? QLocale().formattedDataSize(it.bytes) : QString();
        QStringList names;
        for (const QString& f : it.files.mid(0, 6))
            names << QFileInfo(f).fileName();
        m["names"] = names;
    } else if (!it.image.isNull()) {
        m["kind"] = "image";
        m["title"] = tr("Image");
        m["detail"] = QStringLiteral("%1 × %2").arg(it.image.width()).arg(it.image.height());
        m["thumb"] = thumbUrl(it.image);
    } else {
        const QString text = plainOf(it);
        QString first;
        for (const QString& line : text.split('\n'))
            if (!line.trimmed().isEmpty()) {
                first = line.trimmed();
                break;
            }
        if (first.size() > 90)
            first = first.left(89) + QChar(0x2026);
        m["kind"] = "text";
        m["title"] = first.isEmpty() ? tr("Blank text") : first;
        m["detail"] = it.html.isEmpty() ? tr("%n characters", nullptr, int(text.size()))
                                        : tr("Formatted text · %n characters", nullptr, int(text.size()));
        m["text"] = text.left(2000);
    }
    return m;
}

void ClipHistory::add(const ClipItem& item, bool fromServer, const QString& origin)
{
    if (item.isEmpty() || item.concealed)
        return;
    QVariantMap preview = describe(item);
    // Collapse an immediate repeat (the same text copied twice).
    if (!m_entries.empty() && m_entries.front().preview == preview && m_entries.front().fromServer == fromServer)
        m_entries.pop_front();
    m_entries.push_front({m_nextId++, fromServer, origin, QDateTime::currentMSecsSinceEpoch(), item, preview});
    while (m_entries.size() > size_t(kHistoryMax))
        m_entries.pop_back();
    emit changed();
}

ClipItem ClipHistory::item(int id) const
{
    for (const Entry& e : m_entries)
        if (e.id == id)
            return e.item;
    return {};
}

QVariantList ClipHistory::items() const
{
    QVariantList out;
    for (const Entry& e : m_entries) {
        QVariantMap m = e.preview;
        m["id"] = e.id;
        m["source"] = e.fromServer ? "server" : "mac";
        m["origin"] = e.origin;
        m["time"] = e.time;
        m["search"] = (m.value("title").toString() + ' ' + m.value("text").toString() + ' '
                       + m.value("names").toStringList().join(' ') + ' ' + e.origin).toLower();
        out << m;
    }
    return out;
}

// ---------------------------------------------------------------- callbacks

struct ClipCallbacks {
    static RdpClipboard* self(CliprdrClientContext* c)
    {
        return static_cast<RdpClipboard*>(cliprdr_file_context_get_context(static_cast<CliprdrFileContext*>(c->custom)));
    }

    static UINT serverCaps(CliprdrClientContext* c, const CLIPRDR_CAPABILITIES* caps)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        s->m_remoteFlags = 0;
        const BYTE* p = reinterpret_cast<const BYTE*>(caps->capabilitySets);
        for (UINT32 i = 0; i < caps->cCapabilitiesSets; ++i) {
            const auto* set = reinterpret_cast<const CLIPRDR_CAPABILITY_SET*>(p);
            if (set->capabilitySetType == CB_CAPSTYPE_GENERAL)
                s->m_remoteFlags = reinterpret_cast<const CLIPRDR_GENERAL_CAPABILITY_SET*>(set)->generalFlags;
            if (!set->capabilitySetLength)
                break;
            p += set->capabilitySetLength;
        }
        (void)cliprdr_file_context_remote_set_flags(s->m_file, s->m_remoteFlags);
        return CHANNEL_RC_OK;
    }

    static UINT monitorReady(CliprdrClientContext* c, const CLIPRDR_MONITOR_READY*)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        (void)cliprdr_file_context_set_locally_available(s->m_file, TRUE);
        CLIPRDR_GENERAL_CAPABILITY_SET general{};
        general.capabilitySetType = CB_CAPSTYPE_GENERAL;
        general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
        general.version = CB_CAPS_VERSION_2;
        // File streaming (both directions) only when the server offered it too.
        general.generalFlags = CB_USE_LONG_FORMAT_NAMES | cliprdr_file_context_current_flags(s->m_file);
        CLIPRDR_CAPABILITIES caps{};
        caps.cCapabilitiesSets = 1;
        caps.capabilitySets = reinterpret_cast<CLIPRDR_CAPABILITY_SET*>(&general);
        const UINT rc = c->ClientCapabilities(c, &caps);
        if (rc != CHANNEL_RC_OK)
            return rc;
        s->m_ready = true;
        const bool files = (general.generalFlags & CB_STREAM_FILECLIP_ENABLED) != 0;
        s->post([s, files] {
            s->m_available = true;
            s->m_unavailable = false;
            s->m_filesOk = files;
            s->m_availTimer.stop();
            emit s->availableChanged();
        });
        s->sendFormatList();
        return CHANNEL_RC_OK;
    }

    static UINT serverFormatList(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST* list)
    {
        RdpClipboard* s = self(c);
        CLIPRDR_FORMAT_LIST_RESPONSE resp{};
        resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
        resp.common.msgFlags = CB_RESPONSE_OK;
        const UINT rc = c->ClientFormatListResponse(c, &resp);
        if (rc != CHANNEL_RC_OK)
            return rc;

        QMutexLocker lock(&s->m_mx);
        (void)cliprdr_file_context_notify_new_server_format_list(s->m_file);
        // A new server clipboard invalidates the file streams of the old one.
        if (s->m_dl.active)
            s->dlAbort(RdpClipboard::tr("The server clipboard changed during the transfer."));
        s->m_serverFormats.clear();
        for (UINT32 i = 0; i < list->numFormats; ++i)
            s->m_serverFormats.emplace_back(list->formats[i].formatId,
                                            QString::fromUtf8(list->formats[i].formatName));
        if (!allowsToMac(s->m_modeA)) {
            s->m_fetch.clear();
            return CHANNEL_RC_OK;
        }
        if (s->m_awaiting) {
            s->m_refetch = true; // plan once the outstanding response is in
            return CHANNEL_RC_OK;
        }
        s->planFetch();
        s->requestNextFetch();
        return CHANNEL_RC_OK;
    }

    static UINT serverFormatListResponse(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST_RESPONSE* resp)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        if (!s->m_pasteQueued)
            return CHANNEL_RC_OK;
        s->m_pasteQueued = false;
        const QPointF pos = s->m_pastePos;
        const bool click = s->m_pasteClick;
        const bool ok = resp->common.msgFlags & CB_RESPONSE_OK;
        s->post([s, pos, click, ok] {
            if (ok)
                emit s->pasteReady(pos, click);
            else
                s->setActivity({{"kind", "error"}, {"dir", "toServer"}, {"title", RdpClipboard::tr("Paste failed")},
                                {"detail", RdpClipboard::tr("The server refused the clipboard contents.")}});
        });
        return CHANNEL_RC_OK;
    }

    static UINT serverFormatDataRequest(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* req)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        const ClipItem it = s->m_offer;
        QByteArray data;
        BYTE* owned = nullptr;
        UINT32 ownedLen = 0;
        switch (req->requestedFormatId) {
        case CF_UNICODETEXT:
            if (!it.text.isEmpty())
                data = utf16Crlf(it.text);
            break;
        case CF_DIB:
            data = encodeDib(it.image);
            break;
        case kFmtPng: {
            QBuffer buf(&data);
            buf.open(QIODevice::WriteOnly);
            if (!it.image.isNull())
                it.image.save(&buf, "PNG");
            break;
        }
        case kFmtHtml:
            if (!it.html.isEmpty())
                data = encodeCfHtml(it.html);
            break;
        case kFmtFiles:
            s->serializeFiles(it, &owned, &ownedLen);
            break;
        default:
            break;
        }
        CLIPRDR_FORMAT_DATA_RESPONSE resp{};
        resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
        if (owned) {
            resp.common.msgFlags = CB_RESPONSE_OK;
            resp.common.dataLen = ownedLen;
            resp.requestedFormatData = owned;
        } else if (!data.isEmpty()) {
            resp.common.msgFlags = CB_RESPONSE_OK;
            resp.common.dataLen = UINT32(data.size());
            resp.requestedFormatData = reinterpret_cast<const BYTE*>(data.constData());
        } else {
            resp.common.msgFlags = CB_RESPONSE_FAIL;
        }
        const UINT rc = c->ClientFormatDataResponse(c, &resp);
        free(owned);
        return rc;
    }

    static UINT serverFormatDataResponse(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_RESPONSE* resp)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        s->m_awaiting = false;
        if (s->m_refetch) {
            s->m_refetch = false;
            s->planFetch();
            s->requestNextFetch();
            return CHANNEL_RC_OK;
        }
        if (s->m_fetch.empty())
            return CHANNEL_RC_OK;
        const int kind = s->m_fetch.front().kind;
        s->m_fetch.pop_front();
        if ((resp->common.msgFlags & CB_RESPONSE_OK) && resp->requestedFormatData && resp->common.dataLen) {
            const QByteArray data(reinterpret_cast<const char*>(resp->requestedFormatData), int(resp->common.dataLen));
            switch (kind) {
            case KFiles: s->parseFiles(data); break;
            case KPng: s->m_incoming.image = QImage::fromData(data, "PNG"); break;
            case KDib: s->m_incoming.image = decodeDib(data); break;
            case KHtml: s->m_incoming.html = decodeCfHtml(data); break;
            case KUtf16: s->m_incoming.text = fromWire(data, true); break;
            case KAnsi: s->m_incoming.text = fromWire(data, false); break;
            }
        }
        s->requestNextFetch();
        return CHANNEL_RC_OK;
    }

    // Wraps FreeRDP's local file server to observe (and cancel) uploads.
    static UINT serverFileContentsRequest(CliprdrClientContext* c, const CLIPRDR_FILE_CONTENTS_REQUEST* req)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        if (req->dwFlags & FILECONTENTS_RANGE) {
            if (!s->m_upActive) {
                s->m_upActive = true;
                s->m_upSent = 0;
                s->m_cancel = false;
                s->m_upTick.start();
                const int n = s->m_upCount;
                s->post([s, n] { s->setTransfer(true, 0, RdpClipboard::tr("Pasting %n file(s)", nullptr, n), "toServer"); });
            }
            if (s->m_cancel) {
                CLIPRDR_FILE_CONTENTS_RESPONSE fail{};
                fail.common.msgType = CB_FILECONTENTS_RESPONSE;
                fail.common.msgFlags = CB_RESPONSE_FAIL;
                fail.streamId = req->streamId;
                s->m_upActive = false;
                return c->ClientFileContentsResponse(c, &fail);
            }
            s->m_upSent += req->cbRequested;
            const qint64 total = qMax<qint64>(1, s->m_upTotal);
            if (s->m_upSent >= total) {
                s->m_upActive = false;
                const int n = s->m_upCount;
                const qint64 bytes = s->m_upTotal;
                s->post([s, n, bytes] {
                    s->setTransfer(false, 1, QString(), QString());
                    s->setActivity({{"kind", "files"}, {"dir", "toServer"},
                                    {"title", RdpClipboard::tr("Pasted %n file(s)", nullptr, n)},
                                    {"detail", QLocale().formattedDataSize(bytes)}});
                });
            } else if (s->m_upTick.elapsed() > kTickMs) {
                s->m_upTick.restart();
                const qreal p = qreal(s->m_upSent) / qreal(total);
                s->post([s, p] { s->setTransfer(true, p, s->m_transferText, s->m_transferDir); });
            }
        }
        auto orig = reinterpret_cast<pcCliprdrServerFileContentsRequest>(s->m_origFileRequest);
        return orig ? orig(c, req) : CHANNEL_RC_OK;
    }

    static UINT serverFileContentsResponse(CliprdrClientContext* c, const CLIPRDR_FILE_CONTENTS_RESPONSE* resp)
    {
        RdpClipboard* s = self(c);
        QMutexLocker lock(&s->m_mx);
        auto& dl = s->m_dl;
        if (!dl.active || resp->streamId != dl.streamId)
            return CHANNEL_RC_OK;
        if (s->m_cancel) {
            s->dlAbort(QString());
            return CHANNEL_RC_OK;
        }
        if (!(resp->common.msgFlags & CB_RESPONSE_OK)) {
            s->dlAbort(RdpClipboard::tr("The server stopped the transfer."));
            return CHANNEL_RC_OK;
        }
        auto& e = dl.entries[dl.index];
        if (dl.sizing) {
            dl.sizing = false;
            quint64 size = 0;
            if (resp->cbRequested >= 8 && resp->requestedData)
                std::memcpy(&size, resp->requestedData, 8);
            e.size = qint64(qFromLittleEndian(size));
            dl.total += e.size;
            if (e.size == 0) {
                s->dlCloseFile();
                ++dl.index;
                s->dlNext();
            } else {
                s->dlRequest(FILECONTENTS_RANGE, 0, quint32(qMin<qint64>(e.size, kChunk)));
            }
            return CHANNEL_RC_OK;
        }
        const qint64 n = resp->requestedData ? resp->cbRequested : 0;
        if (n > 0 && dl.out->write(reinterpret_cast<const char*>(resp->requestedData), n) != n) {
            s->dlAbort(RdpClipboard::tr("Couldn’t write to %1.").arg(dl.out->fileName()));
            return CHANNEL_RC_OK;
        }
        dl.offset += n;
        dl.done += n;
        if (dl.tick.elapsed() > kTickMs) {
            dl.tick.restart();
            const qreal p = dl.total > 0 ? qreal(dl.done) / qreal(dl.total) : 0;
            s->post([s, p] { s->setTransfer(true, p, s->m_transferText, s->m_transferDir); });
        }
        if (n == 0 || dl.offset >= e.size) {
            s->dlCloseFile();
            ++dl.index;
            s->dlNext();
        } else {
            s->dlRequest(FILECONTENTS_RANGE, dl.offset, quint32(qMin<qint64>(e.size - dl.offset, kChunk)));
        }
        return CHANNEL_RC_OK;
    }
};

// ---------------------------------------------------------------- RdpClipboard

RdpClipboard::RdpClipboard(RdpSession* session)
    : QObject(session)
    , m_session(session)
{
    m_wclip = ClipboardCreate();
    m_file = cliprdr_file_context_new(this);
    m_availTimer.setSingleShot(true);
    m_availTimer.setInterval(6000);
    connect(&m_availTimer, &QTimer::timeout, this, [this] {
        if (m_available)
            return;
        m_unavailable = true;
        emit availableChanged();
    });
    m_stall.setSingleShot(true);
    m_stall.setInterval(20000);
    connect(&m_stall, &QTimer::timeout, this, [this] {
        {
            QMutexLocker lock(&m_mx);
            if (m_dl.active)
                return; // downloads end through dlAbort/dlNext
            m_upActive = false;
        }
        setTransfer(false, 0, QString(), QString());
    });
}

RdpClipboard::~RdpClipboard()
{
    m_dl.out.reset();
    if (m_file)
        cliprdr_file_context_free(m_file);
    if (m_wclip)
        ClipboardDestroy(m_wclip);
}

void RdpClipboard::post(std::function<void()> fn)
{
    QMetaObject::invokeMethod(this, std::move(fn), Qt::QueuedConnection);
}

void RdpClipboard::wake()
{
    m_session->wake();
}

void RdpClipboard::setMode(int m)
{
    if (m == m_mode || m < Both || m > Off)
        return;
    const bool wasToServer = allowsToServer(m_mode);
    m_mode = m;
    m_modeA = m;
    emit modeChanged();
    if (allowsToServer(m) && !wasToServer)
        setLocal(captureSystem(false));
    else if (!allowsToServer(m) && wasToServer)
        offer(ClipItem{}, false, {}, false); // withdraw what the server can still paste
}

void RdpClipboard::setActivity(QVariantMap a)
{
    a["seq"] = ++m_activitySeq;
    m_activity = a;
    emit activityChanged();
}

void RdpClipboard::setTransfer(bool busy, qreal progress, const QString& text, const QString& dir)
{
    m_busy = busy;
    m_progress = qBound<qreal>(0, progress, 1);
    m_transferText = text;
    m_transferDir = dir;
    if (busy)
        m_stall.start();
    else
        m_stall.stop();
    emit transferChanged();
}

void RdpClipboard::sessionConnected()
{
    if (!m_available)
        m_availTimer.start();
}

void RdpClipboard::notAvailable()
{
    setActivity({{"kind", "error"}, {"dir", "toServer"},
                 {"title", m_unavailable ? tr("Clipboard sharing is off on this server")
                                         : tr("The clipboard isn’t ready yet")},
                 {"detail", m_unavailable ? tr("The server doesn’t allow clipboard redirection.")
                                          : tr("Try again in a moment.")}});
}

ClipItem RdpClipboard::captureSystem(bool record)
{
    ClipItem it;
    const QMimeData* m = QGuiApplication::clipboard()->mimeData();
    if (!m)
        return it;
    if (const quintptr o = MacPasteboard::lazyOrigin()) {
        it.origin = o; // lazily offered server files: reading them would start the download
        return it;
    }
    if (MacPasteboard::isConcealed()) {
        it.concealed = true;
        return it;
    }
    if (m->hasFormat(QLatin1String(kOriginMime)))
        it.origin = quintptr(m->data(QLatin1String(kOriginMime)).toULongLong());
    for (const QUrl& u : m->urls())
        if (u.isLocalFile())
            it.files << u.toLocalFile();
    if (!it.files.isEmpty())
        measure(it.files, &it.bytes, &it.fileCount);
    else if (m->hasImage())
        it.image = qvariant_cast<QImage>(m->imageData());
    if (it.files.isEmpty() && m->hasHtml())
        it.html = m->html();
    if (m->hasText())
        it.text = m->text();
    if (record && !it.origin)
        ClipHistory::instance()->add(it, false, tr("Mac"));
    return it;
}

void RdpClipboard::setLocal(const ClipItem& item)
{
    m_system = item;
    if (item.origin == quintptr(this) || (item.origin && item.isEmpty()) || !allowsToServer(m_mode))
        return; // our own server's data coming back, nothing to offer, or sync to the server is off
    if (item.concealed) {
        offer(ClipItem{}, false, {}, false);
        setActivity({{"kind", "concealed"}, {"dir", "toServer"}, {"title", tr("Not shared")},
                     {"detail", tr("Concealed item")}});
        return;
    }
    offer(item, false, {}, false);
    if (item.isEmpty())
        return;
    if (!m_available) {
        if (m_unavailable && !m_warnedUnavailable) {
            m_warnedUnavailable = true;
            notAvailable();
        }
        return;
    }
    QVariantMap a = ClipHistory::describe(item);
    if (!item.files.isEmpty() && !m_filesOk) {
        a["kind"] = "error";
        a["detail"] = tr("This server doesn’t accept files over the clipboard.");
    }
    a["dir"] = "toServer";
    setActivity(a);
}

void RdpClipboard::offer(const ClipItem& item, bool paste, const QPointF& pos, bool click)
{
    {
        QMutexLocker lock(&m_mx);
        m_offer = item;
        m_offerDirty = true;
        m_upTotal = item.bytes;
        m_upCount = item.fileCount;
        if (paste) {
            m_pasteArmed = true;
            m_pastePos = pos;
            m_pasteClick = click;
        }
    }
    wake();
}

void RdpClipboard::pasteItem(const ClipItem& source, bool plain, const QPointF& remotePos, bool click)
{
    if (!m_available) {
        notAvailable();
        return;
    }
    ClipItem item = source;
    if (plain) {
        item = ClipItem{};
        item.text = plainOf(source);
    }
    if (item.isEmpty())
        return;
    item.origin = 0;
    QVariantMap a = ClipHistory::describe(item);
    a["dir"] = "toServer";
    if (!item.files.isEmpty() && !m_filesOk) {
        a["kind"] = "error";
        a["detail"] = tr("This server doesn’t accept files over the clipboard.");
        setActivity(a);
        return;
    }
    setActivity(a);
    offer(item, true, remotePos, click);
}

bool RdpClipboard::dropMime(const QMimeData* m, const QPointF& remotePos)
{
    ClipItem it;
    for (const QUrl& u : m->urls())
        if (u.isLocalFile())
            it.files << u.toLocalFile();
    if (!it.files.isEmpty())
        measure(it.files, &it.bytes, &it.fileCount);
    else if (m->hasImage())
        it.image = qvariant_cast<QImage>(m->imageData());
    else if (m->hasText())
        it.text = m->text();
    if (it.isEmpty())
        return false;
    pasteItem(it, false, remotePos, true);
    return true;
}

void RdpClipboard::pasteHistory(int id, bool plain)
{
    const ClipItem it = ClipHistory::instance()->item(id);
    if (!it.isEmpty())
        pasteItem(it, plain, {}, false);
}

void RdpClipboard::pastePlainText()
{
    const ClipItem it = captureSystem(false);
    if (it.concealed) {
        setActivity({{"kind", "concealed"}, {"dir", "toServer"}, {"title", tr("Not shared")},
                     {"detail", tr("Concealed item")}});
        return;
    }
    pasteItem(it, true, {}, false);
}

void RdpClipboard::cancelTransfer()
{
    m_cancel = true;
    m_pendingFiles.clear();
    wake();
    const bool toMac = m_transferDir == QLatin1String("toMac");
    setTransfer(false, 0, QString(), QString());
    setActivity({{"kind", "info"}, {"dir", toMac ? "toMac" : "toServer"}, {"title", tr("Transfer cancelled")}});
}

void RdpClipboard::download()
{
    if (!m_pendingFiles.empty() && !m_busy) {
        startDownload(std::move(m_pendingFiles), false);
        m_pendingFiles.clear();
    }
}

void RdpClipboard::reveal()
{
    if (!m_saved.isEmpty())
        MacPasteboard::revealInFinder(m_saved);
}

QVariantMap RdpClipboard::dragData()
{
    const ClipItem& it = m_lastRemote;
    QStringList paths = it.files;
    if (paths.isEmpty() && !it.image.isNull()) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation) + "/Perch";
        QDir().mkpath(dir);
        const QString path = dir + "/" + tr("Server image") + " "
                             + QDateTime::currentDateTime().toString("yyyy-MM-dd HH.mm.ss") + ".png";
        if (it.image.save(path, "PNG"))
            paths << path;
    }
    if (!paths.isEmpty()) {
        QStringList urls;
        for (const QString& p : paths)
            urls << QString::fromUtf8(QUrl::fromLocalFile(p).toEncoded());
        return {{"text/uri-list", urls.join("\r\n")}};
    }
    if (!it.text.isEmpty())
        return {{"text/plain", it.text}};
    return {};
}

void RdpClipboard::applyRemote(const ClipItem& source)
{
    ClipItem item = source;
    item.origin = quintptr(this);
    m_lastRemote = item;
    auto* mime = new QMimeData;
    if (!item.text.isEmpty())
        mime->setText(item.text);
    if (!item.html.isEmpty())
        mime->setHtml(item.html);
    if (!item.image.isNull())
        mime->setImageData(item.image);
    if (!item.files.isEmpty()) {
        QList<QUrl> urls;
        for (const QString& f : item.files)
            urls << QUrl::fromLocalFile(f);
        mime->setUrls(urls);
    }
    mime->setData(QLatin1String(kOriginMime), QByteArray::number(quint64(item.origin)));
    QGuiApplication::clipboard()->setMimeData(mime);
    ClipHistory::instance()->add(item, true, m_session->title());

    QVariantMap a = ClipHistory::describe(item);
    a["dir"] = "toMac";
    if (!item.files.isEmpty()) {
        a["detail"] = a.value("title").toString() + QStringLiteral(" · ") + a.value("detail").toString();
        a["title"] = tr("Saved to Downloads");
        a["action"] = "reveal";
    }
    setActivity(a);
}

void RdpClipboard::remoteFilesListed(std::vector<RemoteEntry> entries)
{
    qint64 total = 0;
    int files = 0;
    bool known = true;
    for (const RemoteEntry& e : entries) {
        if (e.dir || e.rel.isEmpty())
            continue;
        ++files;
        if (e.size < 0)
            known = false;
        else
            total += e.size;
    }
    if (!files && entries.empty())
        return;
    // Copying files on the server is often not meant for the Mac: put them on the
    // Mac clipboard as promises fetched only when pasted, and offer a Download.
    QStringList tops;
    for (const RemoteEntry& e : entries) {
        const QString top = e.rel.section('/', 0, 0);
        if (!top.isEmpty() && !tops.contains(top))
            tops << top;
    }
    m_lazyEntries = entries;
    m_lazyState = LazyIdle;
    m_lazyPaths.clear();
    const quint64 gen = ++m_lazyGen;
    const bool lazy = allowsToMac(m_mode)
                      && MacPasteboard::offerLazyFiles(tops, quintptr(this), [guard = QPointer<RdpClipboard>(this), gen] {
                             return guard ? guard->provideLazy(gen) : QStringList();
                         });
    m_pendingFiles = std::move(entries);
    if (m_busy)
        return; // a transfer is running; the user can download this one after
    QString detail = known ? QLocale().formattedDataSize(total) : QString();
    if (lazy)
        detail += (detail.isEmpty() ? QString() : QStringLiteral(" · ")) + tr("Paste in Finder to copy");
    setActivity({{"kind", "files"}, {"dir", "toMac"}, {"title", tr("%n file(s) on the server", nullptr, files)},
                 {"detail", detail}, {"action", "download"}});
}

QStringList RdpClipboard::provideLazy(quint64 gen)
{
    if (gen != m_lazyGen || m_lazyEntries.empty())
        return {};
    if (m_lazyState == LazyIdle) {
        if (m_busy || !m_cliprdr)
            return {}; // another transfer is running, or the session is gone
        startDownload(m_lazyEntries, true);
    }
    if (m_lazyState == LazyLoading) {
        // The pasting app waits on this call; keep Perch responsive meanwhile and
        // give up if the server stops sending.
        QEventLoop loop;
        connect(this, &RdpClipboard::lazySettled, &loop, &QEventLoop::quit);
        QTimer watchdog;
        watchdog.setInterval(20000);
        qint64 last = -1;
        connect(&watchdog, &QTimer::timeout, &loop, [&] {
            qint64 done;
            {
                QMutexLocker lock(&m_mx);
                done = m_dl.done;
            }
            if (done == last) {
                cancelTransfer();
                m_lazyState = LazyIdle;
                loop.quit();
            }
            last = done;
        });
        watchdog.start();
        loop.exec();
    }
    return gen == m_lazyGen && m_lazyState == LazyDone ? m_lazyPaths : QStringList();
}

void RdpClipboard::startDownload(std::vector<RemoteEntry> entries, bool lazy)
{
    QString root;
    if (lazy) {
        // A fresh folder per paste keeps the server's names; the paster copies from it.
        if (!m_lazyRoot.isEmpty())
            QDir(m_lazyRoot).removeRecursively();
        root = m_lazyRoot = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/paste/"
                            + QUuid::createUuid().toString(QUuid::WithoutBraces);
    } else {
        QString server = m_session->title();
        server.replace(QRegularExpression(QStringLiteral("[/\\\\:]")), QStringLiteral("_"));
        root = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation) + "/Perch/" + server;
    }
    if (!QDir().mkpath(root)) {
        setActivity({{"kind", "error"}, {"dir", "toMac"}, {"title", tr("Couldn’t save files")},
                     {"detail", tr("%1 isn’t writable.").arg(root)}});
        return;
    }
    // Never overwrite: give a clashing top-level item a " 2", " 3"… suffix and
    // carry the new name down to its children.
    QHash<QString, QString> renamed;
    QStringList tops;
    qint64 total = 0;
    int files = 0;
    for (RemoteEntry& e : entries) {
        if (e.rel.isEmpty())
            continue;
        const int slash = int(e.rel.indexOf('/'));
        const QString top = slash < 0 ? e.rel : e.rel.left(slash);
        if (!renamed.contains(top)) {
            QString name = top;
            const QFileInfo fi(top);
            const QString base = fi.completeBaseName().isEmpty() ? top : fi.completeBaseName();
            const QString ext = fi.completeBaseName().isEmpty() || fi.suffix().isEmpty() ? QString() : "." + fi.suffix();
            for (int n = 2; QFileInfo::exists(root + "/" + name); ++n)
                name = QStringLiteral("%1 %2%3").arg(base).arg(n).arg(ext);
            renamed.insert(top, name);
            tops << root + "/" + name;
        }
        e.rel = renamed.value(top) + (slash < 0 ? QString() : e.rel.mid(slash));
        if (!e.dir) {
            ++files;
            total += qMax<qint64>(0, e.size);
        }
    }
    if (lazy) {
        m_lazyPaths = tops;
        m_lazyState = LazyLoading;
    } else {
        m_saved = tops;
    }
    {
        QMutexLocker lock(&m_mx);
        m_dl.lazy = lazy;
        m_dl.entries = std::move(entries);
        m_dl.root = root;
        m_dl.index = 0;
        m_dl.done = 0;
        m_dl.total = total;
        m_dl.active = true;
        m_dl.tick.start();
        m_dlStart = true;
        m_cancel = false;
    }
    setTransfer(true, 0, tr("Saving %n file(s)", nullptr, files), "toMac");
    wake();
}

// ---------------------------------------------------------------- worker side

void RdpClipboard::attach(CliprdrClientContext* c)
{
    QMutexLocker lock(&m_mx);
    m_cliprdr = c;
    m_ready = false;
    if (m_file)
        (void)cliprdr_file_context_init(m_file, c); // sets c->custom and the lock/file handlers
    m_origFileRequest = reinterpret_cast<void*>(c->ServerFileContentsRequest);
    c->ServerCapabilities = ClipCallbacks::serverCaps;
    c->MonitorReady = ClipCallbacks::monitorReady;
    c->ServerFormatList = ClipCallbacks::serverFormatList;
    c->ServerFormatListResponse = ClipCallbacks::serverFormatListResponse;
    c->ServerFormatDataRequest = ClipCallbacks::serverFormatDataRequest;
    c->ServerFormatDataResponse = ClipCallbacks::serverFormatDataResponse;
    c->ServerFileContentsRequest = ClipCallbacks::serverFileContentsRequest;
    c->ServerFileContentsResponse = ClipCallbacks::serverFileContentsResponse;
}

void RdpClipboard::detach()
{
    QMutexLocker lock(&m_mx);
    if (!m_cliprdr)
        return;
    if (m_dl.active)
        dlAbort(tr("The connection closed during the transfer."));
    if (m_file)
        (void)cliprdr_file_context_uninit(m_file, m_cliprdr);
    m_cliprdr = nullptr;
    m_ready = false;
    m_awaiting = m_refetch = false;
    m_fetch.clear();
    m_pasteQueued = false;
    m_upActive = false;
    post([this] {
        m_available = false;
        emit availableChanged();
        if (m_busy)
            setTransfer(false, 0, QString(), QString());
    });
}

void RdpClipboard::processPending()
{
    QMutexLocker lock(&m_mx);
    if (m_offerDirty) {
        m_offerDirty = false;
        sendFormatList();
    }
    if (m_dl.active && m_cancel) {
        dlAbort(QString());
        return;
    }
    if (m_dlStart) {
        m_dlStart = false;
        if (m_cliprdr && m_ready)
            dlNext();
        else
            dlAbort(tr("The clipboard channel isn’t connected."));
    }
}

void RdpClipboard::sendFormatList()
{
    if (!m_cliprdr || !m_ready)
        return;
    const bool files = cliprdr_file_context_current_flags(m_file) & CB_STREAM_FILECLIP_ENABLED;
    std::vector<CLIPRDR_FORMAT> formats;
    if (!m_offer.files.isEmpty() && files)
        formats.push_back({kFmtFiles, const_cast<char*>(kNameFiles)});
    if (!m_offer.image.isNull()) {
        formats.push_back({CF_DIB, nullptr});
        formats.push_back({kFmtPng, const_cast<char*>(kNamePng)});
    }
    if (!m_offer.html.isEmpty())
        formats.push_back({kFmtHtml, const_cast<char*>(kNameHtml)});
    if (!m_offer.text.isEmpty())
        formats.push_back({CF_UNICODETEXT, nullptr});
    CLIPRDR_FORMAT_LIST list{};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = UINT32(formats.size());
    list.formats = formats.empty() ? nullptr : formats.data();
    if (m_cliprdr->ClientFormatList(m_cliprdr, &list) != CHANNEL_RC_OK)
        return;
    (void)cliprdr_file_context_notify_new_client_format_list(m_file);
    if (m_pasteArmed) {
        m_pasteArmed = false;
        m_pasteQueued = true;
    }
}

void RdpClipboard::serializeFiles(const ClipItem& it, unsigned char** out, quint32* outLen)
{
    // WinPR synthesises FILEDESCRIPTORW entries from a text/uri-list, and the
    // file context serves the matching FILECONTENTS requests from the same list.
    QByteArray uris;
    for (const QString& f : it.files)
        uris += QUrl::fromLocalFile(f).toEncoded() + "\r\n";
    if (uris.isEmpty() || !m_wclip)
        return;
    ClipboardLock(m_wclip);
    const UINT32 uriId = ClipboardRegisterFormat(m_wclip, "text/uri-list");
    const UINT32 fgdId = ClipboardRegisterFormat(m_wclip, kNameFiles);
    UINT32 size = 0;
    void* descs = nullptr;
    if (ClipboardSetData(m_wclip, uriId, uris.constData(), UINT32(uris.size())))
        descs = ClipboardGetData(m_wclip, fgdId, &size);
    if (descs) {
        const auto* array = static_cast<const FILEDESCRIPTORW*>(descs);
        const UINT32 count = size / sizeof(FILEDESCRIPTORW);
        if (cliprdr_serialize_file_list_ex(cliprdr_file_context_remote_get_flags(m_file), array, count, out, outLen)
            == CHANNEL_RC_OK)
            (void)cliprdr_file_context_update_client_data(m_file, uris.constData(), size_t(uris.size()));
        free(descs);
    }
    ClipboardUnlock(m_wclip);
}

void RdpClipboard::parseFiles(const QByteArray& data)
{
    FILEDESCRIPTORW* array = nullptr;
    UINT32 count = 0;
    if (cliprdr_parse_file_list(reinterpret_cast<const BYTE*>(data.constData()), UINT32(data.size()), &array, &count)
        != CHANNEL_RC_OK)
        return;
    m_incomingFiles.clear();
    for (UINT32 i = 0; i < count; ++i) {
        const FILEDESCRIPTORW& d = array[i];
        RemoteEntry e;
        const auto* name = reinterpret_cast<const char16_t*>(d.cFileName);
        qsizetype len = 0;
        while (len < qsizetype(ARRAYSIZE(d.cFileName)) && name[len])
            ++len;
        e.rel = sanitizeRel(QString::fromUtf16(name, len));
        e.dir = (d.dwFlags & FD_ATTRIBUTES) && (d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        if (d.dwFlags & FD_FILESIZE)
            e.size = (qint64(d.nFileSizeHigh) << 32) | d.nFileSizeLow;
        m_incomingFiles.push_back(e); // keep every entry: the index is the server's listIndex
    }
    free(array);
}

void RdpClipboard::planFetch()
{
    m_fetch.clear();
    m_incoming = ClipItem{};
    m_incomingFiles.clear();
    auto byName = [&](const char* name) -> quint32 {
        for (const auto& f : m_serverFormats)
            if (f.second == QLatin1String(name))
                return f.first;
        return 0;
    };
    auto has = [&](quint32 id) {
        for (const auto& f : m_serverFormats)
            if (f.first == id)
                return true;
        return false;
    };
    const quint32 files = byName(kNameFiles);
    if (files && (cliprdr_file_context_current_flags(m_file) & CB_STREAM_FILECLIP_ENABLED)) {
        m_fetch.push_back({files, KFiles});
        return;
    }
    if (const quint32 png = byName(kNamePng))
        m_fetch.push_back({png, KPng});
    else if (has(CF_DIBV5))
        m_fetch.push_back({CF_DIBV5, KDib});
    else if (has(CF_DIB))
        m_fetch.push_back({CF_DIB, KDib});
    if (const quint32 html = byName(kNameHtml))
        m_fetch.push_back({html, KHtml});
    if (has(CF_UNICODETEXT))
        m_fetch.push_back({CF_UNICODETEXT, KUtf16});
    else if (has(CF_TEXT))
        m_fetch.push_back({CF_TEXT, KAnsi});
}

void RdpClipboard::requestNextFetch()
{
    if (m_fetch.empty()) {
        finishFetch();
        return;
    }
    if (!m_cliprdr)
        return;
    CLIPRDR_FORMAT_DATA_REQUEST req{};
    req.common.msgType = CB_FORMAT_DATA_REQUEST;
    req.requestedFormatId = m_fetch.front().id;
    if (m_cliprdr->ClientFormatDataRequest(m_cliprdr, &req) == CHANNEL_RC_OK)
        m_awaiting = true;
    else
        m_fetch.clear();
}

void RdpClipboard::finishFetch()
{
    if (!m_incomingFiles.empty()) {
        post([this, entries = std::move(m_incomingFiles)]() mutable { remoteFilesListed(std::move(entries)); });
        m_incomingFiles.clear();
    } else if (!m_incoming.isEmpty()) {
        post([this, item = m_incoming] {
            m_pendingFiles.clear(); // the server clipboard no longer holds those files
            m_lazyEntries.clear();
            ++m_lazyGen;
            applyRemote(item);
        });
    }
    m_incoming = ClipItem{};
}

void RdpClipboard::dlNext()
{
    auto& dl = m_dl;
    while (dl.index < dl.entries.size()) {
        if (m_cancel) {
            dlAbort(QString());
            return;
        }
        const RemoteEntry& e = dl.entries[dl.index];
        if (e.rel.isEmpty()) {
            ++dl.index;
            continue;
        }
        const QString path = dl.root + "/" + e.rel;
        if (e.dir) {
            QDir().mkpath(path);
            ++dl.index;
            continue;
        }
        QDir().mkpath(QFileInfo(path).absolutePath());
        dl.out = std::make_unique<QFile>(path);
        if (!dl.out->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            dlAbort(tr("Couldn’t write %1.").arg(path));
            return;
        }
        dl.offset = 0;
        if (e.size < 0) {
            dl.sizing = true;
            dlRequest(FILECONTENTS_SIZE, 0, 8);
            return;
        }
        if (e.size > 0) {
            dlRequest(FILECONTENTS_RANGE, 0, quint32(qMin<qint64>(e.size, kChunk)));
            return;
        }
        dlCloseFile(); // empty file
        ++dl.index;
    }
    dl.active = false;
    const qint64 bytes = dl.done;
    int count = 0;
    for (const RemoteEntry& e : dl.entries)
        count += (!e.dir && !e.rel.isEmpty()) ? 1 : 0;
    if (dl.lazy) {
        post([this, count] {
            setTransfer(false, 1, QString(), QString());
            m_lazyState = LazyDone;
            setActivity({{"kind", "info"}, {"dir", "toMac"}, {"title", tr("Pasted %n file(s)", nullptr, count)}});
            emit lazySettled();
        });
        return;
    }
    post([this, bytes, count] {
        setTransfer(false, 1, QString(), QString());
        ClipItem it;
        it.files = m_saved;
        it.bytes = bytes;
        it.fileCount = count;
        applyRemote(it);
    });
}

void RdpClipboard::dlRequest(quint32 flags, qint64 offset, quint32 size)
{
    if (!m_cliprdr) {
        dlAbort(tr("The clipboard channel closed."));
        return;
    }
    CLIPRDR_FILE_CONTENTS_REQUEST r{};
    r.common.msgType = CB_FILECONTENTS_REQUEST;
    r.streamId = ++m_dl.streamId;
    r.listIndex = UINT32(m_dl.index);
    r.dwFlags = flags;
    r.nPositionLow = UINT32(quint64(offset) & 0xFFFFFFFFu);
    r.nPositionHigh = UINT32(quint64(offset) >> 32);
    r.cbRequested = size;
    if (m_cliprdr->ClientFileContentsRequest(m_cliprdr, &r) != CHANNEL_RC_OK)
        dlAbort(tr("Couldn’t request the file from the server."));
}

void RdpClipboard::dlCloseFile()
{
    if (m_dl.out)
        m_dl.out->close();
    m_dl.out.reset();
}

void RdpClipboard::dlAbort(const QString& error)
{
    if (m_dl.out) {
        m_dl.out->close();
        m_dl.out->remove(); // never leave a truncated file behind
        m_dl.out.reset();
    }
    m_dl.active = false;
    m_dl.sizing = false;
    m_dlStart = false;
    const bool lazy = m_dl.lazy;
    post([this, error, lazy] {
        if (lazy && m_lazyState == LazyLoading) {
            m_lazyState = LazyIdle; // a later paste can try again
            emit lazySettled();
        }
        setTransfer(false, 0, QString(), QString());
        if (!error.isEmpty())
            setActivity({{"kind", "error"}, {"dir", "toMac"}, {"title", tr("Transfer stopped")}, {"detail", error}});
    });
}
