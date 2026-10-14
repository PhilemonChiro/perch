#include "RdpView.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <winpr/input.h>

namespace {

// Maps a Qt key event to an RDP scancode (with the KBDEXT bit for extended keys).
quint32 rdpScancode(const QKeyEvent* e)
{
#if defined(Q_OS_WIN)
    // Qt on Windows reports the PC scancode with the extended bit at 0x100.
    return e->nativeScanCode() & 0x1FF;
#else
#if defined(Q_OS_MACOS)
    const DWORD vk = GetVirtualKeyCodeFromKeycode(e->nativeVirtualKey(), WINPR_KEYCODE_TYPE_APPLE);
#else
    // X11 and Wayland both report XKB keycodes (evdev + 8).
    const DWORD vk = GetVirtualKeyCodeFromKeycode(e->nativeScanCode(), WINPR_KEYCODE_TYPE_XKB);
#endif
    if (!vk)
        return 0;
    return GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
#endif
}

// Combos that stay with Relay (palette, tabs, fullscreen) instead of the remote.
bool isAppShortcut(const QKeyEvent* e)
{
#if defined(Q_OS_MACOS)
    // Qt maps Cmd to ControlModifier on macOS.
    return e->modifiers() & Qt::ControlModifier;
#else
    const auto m = e->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
    return m == (Qt::ControlModifier | Qt::AltModifier);
#endif
}

quint16 buttonFlag(Qt::MouseButton b)
{
    switch (b) {
    case Qt::LeftButton: return PTR_FLAGS_BUTTON1;
    case Qt::RightButton: return PTR_FLAGS_BUTTON2;
    case Qt::MiddleButton: return PTR_FLAGS_BUTTON3;
    default: return 0;
    }
}

} // namespace

RdpView::RdpView(QQuickItem* parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton);
    setAcceptHoverEvents(true);
    setActiveFocusOnTab(false);
    m_resizeDebounce.setSingleShot(true);
    m_resizeDebounce.setInterval(250);
    connect(&m_resizeDebounce, &QTimer::timeout, this, &RdpView::pushViewport);
}

void RdpView::setSession(RdpSession* s)
{
    if (m_session == s)
        return;
    if (m_session)
        QObject::disconnect(m_session, nullptr, this, nullptr);
    m_session = s;
    if (m_session) {
        connect(m_session, &RdpSession::frameUpdated, this, [this] { m_dirty = true; update(); });
        // Only re-fit the rect on resize; keep the last texture until a real frame
        // arrives (frameUpdated) so a resized/empty buffer never flashes on screen.
        connect(m_session, &RdpSession::remoteSizeChanged, this, [this] { update(); });
        pushViewport();
    }
    m_dirty = true;
    update();
    emit sessionChanged();
}

QRectF RdpView::targetRect() const
{
    if (!m_session || m_session->remoteSize().isEmpty() || width() <= 0 || height() <= 0)
        return {};
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    const QSizeF remote = QSizeF(m_session->remoteSize()) / dpr;
    // Exact 1:1 when the remote matches the viewport, otherwise aspect-fit.
    const qreal s = std::min({1.0, width() / remote.width(), height() / remote.height()});
    const QSizeF sz = remote * s;
    return QRectF(QPointF((width() - sz.width()) / 2, (height() - sz.height()) / 2), sz);
}

QPointF RdpView::toRemote(const QPointF& p) const
{
    const QRectF r = targetRect();
    if (r.isEmpty())
        return {};
    const QSize remote = m_session->remoteSize();
    return {qBound(0.0, (p.x() - r.x()) * remote.width() / r.width(), qreal(remote.width() - 1)),
            qBound(0.0, (p.y() - r.y()) * remote.height() / r.height(), qreal(remote.height() - 1))};
}

QSGNode* RdpView::updatePaintNode(QSGNode* old, UpdatePaintNodeData*)
{
    auto* node = static_cast<QSGSimpleTextureNode*>(old);
    if (!m_session) {
        delete node;
        return nullptr;
    }
    // Refresh the texture only when a real new frame is available. During a
    // resize the remote buffer is briefly reallocated (null frame / empty rect);
    // keep the last frame on screen through that gap rather than flashing black.
    if (m_dirty) {
        const QImage img = m_session->frame();
        if (!img.isNull()) {
            if (!node) {
                node = new QSGSimpleTextureNode;
                node->setOwnsTexture(false);
                node->setFiltering(QSGTexture::Linear);
            }
            QSGTexture* previous = node->texture();
            node->setTexture(window()->createTextureFromImage(img, QQuickWindow::TextureIsOpaque));
            delete previous;
            m_dirty = false;
        }
        // else: leave the node as-is and stay dirty; onEndPaint will update().
    }
    if (!node)
        return nullptr; // nothing drawn yet
    const QRectF rect = targetRect();
    if (!rect.isEmpty())
        node->setRect(rect); // keep the last rect during a transient empty size
    return node;
}

void RdpView::geometryChange(const QRectF& g, const QRectF& old)
{
    QQuickItem::geometryChange(g, old);
    if (g.size() != old.size()) {
        m_resizeDebounce.start();
        update();
    }
}

void RdpView::itemChange(ItemChange change, const ItemChangeData& value)
{
    QQuickItem::itemChange(change, value);
    if (change == ItemSceneChange && value.window) {
        connect(value.window, &QQuickWindow::screenChanged, this, [this] { m_resizeDebounce.start(); });
        m_resizeDebounce.start();
    }
}

void RdpView::pushViewport()
{
    if (!m_session || width() < 1 || height() < 1)
        return;
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    m_session->setViewport(QSize(int(width() * dpr), int(height() * dpr)), dpr);
}

bool RdpView::event(QEvent* e)
{
    // Claim shortcuts so keys like Ctrl+C or Alt+F4 reach the remote session.
    if (e->type() == QEvent::ShortcutOverride) {
        auto* ke = static_cast<QKeyEvent*>(e);
        if (!isAppShortcut(ke)) {
            e->accept();
            return true;
        }
    }
    return QQuickItem::event(e);
}

void RdpView::keyPressEvent(QKeyEvent* e)
{
    if (!m_session)
        return;
    const quint32 sc = rdpScancode(e);
    if (!sc) {
        e->ignore();
        return;
    }
    m_session->sendKey(true, e->isAutoRepeat(), sc);
    m_pressed.insert(sc);
    e->accept();
}

void RdpView::keyReleaseEvent(QKeyEvent* e)
{
    if (!m_session || e->isAutoRepeat())
        return;
    const quint32 sc = rdpScancode(e);
    if (!sc)
        return;
    m_session->sendKey(false, false, sc);
    m_pressed.remove(sc);
    e->accept();
}

void RdpView::releaseAllKeys()
{
    if (m_session)
        for (quint32 sc : std::as_const(m_pressed))
            m_session->sendKey(false, false, sc);
    m_pressed.clear();
}

void RdpView::focusOutEvent(QFocusEvent* e)
{
    // Avoid stuck modifiers when focus moves to the app chrome.
    releaseAllKeys();
    QQuickItem::focusOutEvent(e);
}

void RdpView::mousePressEvent(QMouseEvent* e)
{
    forceActiveFocus(Qt::MouseFocusReason);
    if (m_session)
        if (const quint16 b = buttonFlag(e->button()))
            m_session->sendMouse(PTR_FLAGS_DOWN | b, toRemote(e->position()));
    e->accept();
}

void RdpView::mouseReleaseEvent(QMouseEvent* e)
{
    if (m_session)
        if (const quint16 b = buttonFlag(e->button()))
            m_session->sendMouse(b, toRemote(e->position()));
    e->accept();
}

void RdpView::mouseMoveEvent(QMouseEvent* e)
{
    if (m_session)
        m_session->sendMouse(PTR_FLAGS_MOVE, toRemote(e->position()));
}

void RdpView::hoverMoveEvent(QHoverEvent* e)
{
    if (m_session)
        m_session->sendMouse(PTR_FLAGS_MOVE, toRemote(e->position()));
}

void RdpView::wheelEvent(QWheelEvent* e)
{
    if (!m_session)
        return;
    const QPointF pos = toRemote(e->position());
    // RDP rotation is a 9-bit two's-complement value; 120 per notch like Qt.
    auto send = [&](int& accum, int delta, quint16 kind, bool invert) {
        accum += invert ? -delta : delta;
        while (std::abs(accum) >= 1) {
            const int step = qBound(-255, accum, 255);
            m_session->sendMouse(kind | (quint16(step) & WheelRotationMask), pos);
            accum -= step;
        }
    };
    const QPoint d = e->angleDelta();
    if (d.y())
        send(m_wheelAccumY, d.y(), PTR_FLAGS_WHEEL, false);
    if (d.x())
        send(m_wheelAccumX, d.x(), PTR_FLAGS_HWHEEL, true);
    e->accept();
}
