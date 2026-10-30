#include "RdpView.h"

#include <QMimeData>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <winpr/input.h>

namespace {

// Maps a Qt key event to an RDP scancode (with the KBDEXT bit for extended keys).
// With `cmdAsCtrl`, macOS Cmd becomes Right Ctrl: a distinct scancode from the
// physical Control key, so releasing one never lifts the other, and the Windows
// key (Start menu) is never sent.
quint32 rdpScancode(const QKeyEvent* e, bool cmdAsCtrl)
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
    const quint32 sc = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
#if defined(Q_OS_MACOS)
    if (cmdAsCtrl && (sc == RDP_SCANCODE_LWIN || sc == RDP_SCANCODE_RWIN))
        return RDP_SCANCODE_RCONTROL;
#else
    Q_UNUSED(cmdAsCtrl);
#endif
    return sc;
#endif
}

bool isModifier(quint32 sc)
{
    switch (sc) {
    case RDP_SCANCODE_LCONTROL: case RDP_SCANCODE_RCONTROL:
    case RDP_SCANCODE_LSHIFT: case RDP_SCANCODE_RSHIFT:
    case RDP_SCANCODE_LMENU: case RDP_SCANCODE_RMENU:
    case RDP_SCANCODE_LWIN: case RDP_SCANCODE_RWIN:
        return true;
    default:
        return false;
    }
}

// Combos that stay with Perch (its Shortcuts in Main.qml / SessionPage.qml)
// instead of going to the remote. Keep in sync with those Shortcuts.
bool isAppShortcut(const QKeyEvent* e)
{
    const auto m = e->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
#if defined(Q_OS_MACOS)
    // Qt maps Cmd to ControlModifier (and Control to MetaModifier) on macOS.
    // Every other Cmd combo goes to the remote (as Ctrl, or Win when Cmd-as-Ctrl is off).
    const int k = e->key();
    if (m == (Qt::ControlModifier | Qt::ShiftModifier) && k == Qt::Key_V)
        return true; // clipboard history
    if (m == (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier) && k == Qt::Key_V)
        return true; // paste as plain text
    if (m == (Qt::ControlModifier | Qt::AltModifier) && k == Qt::Key_End)
        return true; // send Ctrl+Alt+Del
    if (m != Qt::ControlModifier)
        return false;
    switch (k) {
    case Qt::Key_K: case Qt::Key_T:              // palette
    case Qt::Key_N:                              // new connection
    case Qt::Key_W:                              // close tab
    case Qt::Key_B:                              // sidebar
    case Qt::Key_Return: case Qt::Key_Enter:     // fullscreen
    case Qt::Key_BracketLeft: case Qt::Key_BracketRight: // previous / next tab
    case Qt::Key_Q: case Qt::Key_H: case Qt::Key_M:      // quit, hide, minimise (macOS)
        return true;
    default:
        return k >= Qt::Key_0 && k <= Qt::Key_9; // Home / tab N
    }
#else
    return m == (Qt::ControlModifier | Qt::AltModifier)
        || m == (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
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
    setFlag(ItemAcceptsDrops, true);
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
        connect(m_session->clipboard(), &RdpClipboard::pasteReady, this, &RdpView::injectPaste);
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
#if defined(Q_OS_MACOS)
    if (translateMacKey(e)) {
        e->accept();
        return;
    }
#endif
    // A mapped key whose modifier was let go keeps auto-repeating; its release
    // is swallowed, so don't start a real press now.
    if (e->isAutoRepeat() && m_mappedKeys.contains(e->key())) {
        e->accept();
        return;
    }
    const quint32 sc = rdpScancode(e, m_session->cmdAsCtrl());
    if (!sc) {
        e->ignore();
        return;
    }
    if (!isModifier(sc))
        restoreLifted();
    m_session->sendKey(true, e->isAutoRepeat(), sc);
    m_pressed.insert(sc);
    e->accept();
}

void RdpView::keyReleaseEvent(QKeyEvent* e)
{
    if (!m_session || e->isAutoRepeat())
        return;
    if (m_mappedKeys.remove(e->key())) {
        e->accept();
        return;
    }
    const quint32 sc = rdpScancode(e, m_session->cmdAsCtrl());
    if (!sc)
        return;
    if (m_lifted.remove(sc)) { // already released on the remote
        e->accept();
        return;
    }
    m_session->sendKey(false, false, sc);
    m_pressed.remove(sc);
    e->accept();
}

// macOS text-navigation chords, translated to their Windows equivalents and sent
// as a single tap (so repeat and release can't leave anything stuck):
//   Cmd+Left/Right -> Home/End        Cmd+Up/Down -> Ctrl+Home/End
//   Opt+Left/Right -> Ctrl+Left/Right Opt+Backspace/Delete -> Ctrl+Backspace/Delete
// Shift stays held, so the Shift+ variants select.
bool RdpView::translateMacKey(QKeyEvent* e)
{
    const auto mods = e->modifiers();
    const bool cmd = mods & Qt::ControlModifier; // Cmd on macOS
    const bool opt = mods & Qt::AltModifier;
    if ((mods & Qt::MetaModifier) || cmd == opt) // physical Control, or none / both
        return false;
    if (cmd && !m_session->cmdAsCtrl())
        return false;
    quint32 key = 0;
    bool ctrl = false;
    switch (e->key()) {
    case Qt::Key_Left: key = cmd ? RDP_SCANCODE_HOME : RDP_SCANCODE_LEFT; ctrl = opt; break;
    case Qt::Key_Right: key = cmd ? RDP_SCANCODE_END : RDP_SCANCODE_RIGHT; ctrl = opt; break;
    case Qt::Key_Up: if (cmd) { key = RDP_SCANCODE_HOME; ctrl = true; } break;
    case Qt::Key_Down: if (cmd) { key = RDP_SCANCODE_END; ctrl = true; } break;
    case Qt::Key_Backspace: if (opt) { key = RDP_SCANCODE_BACKSPACE; ctrl = true; } break;
    case Qt::Key_Delete: if (opt) { key = RDP_SCANCODE_DELETE; ctrl = true; } break;
    default: break;
    }
    if (!key)
        return false;
    const bool tempCtrl = ctrl && !m_pressed.contains(RDP_SCANCODE_RCONTROL)
                          && !m_pressed.contains(RDP_SCANCODE_LCONTROL);
    // Ctrl goes down before Alt is lifted, so the lone Alt release can't
    // activate the remote window's menu bar.
    if (tempCtrl)
        m_session->sendKey(true, false, RDP_SCANCODE_LCONTROL);
    liftModifiers(ctrl);
    tap(key);
    if (tempCtrl)
        m_session->sendKey(false, false, RDP_SCANCODE_LCONTROL);
    m_mappedKeys.insert(e->key());
    return true;
}

// Releases Alt (and Cmd's Ctrl unless `keepCtrl`) on the remote while they stay
// held locally.
void RdpView::liftModifiers(bool keepCtrl)
{
    for (quint32 sc : {RDP_SCANCODE_LMENU, RDP_SCANCODE_RMENU, RDP_SCANCODE_RCONTROL}) {
        if (keepCtrl && sc == RDP_SCANCODE_RCONTROL)
            continue;
        if (!m_pressed.remove(sc))
            continue;
        m_session->sendKey(false, false, sc);
        m_lifted.insert(sc);
    }
}

void RdpView::restoreLifted()
{
    for (quint32 sc : std::as_const(m_lifted)) {
        m_session->sendKey(true, false, sc);
        m_pressed.insert(sc);
    }
    m_lifted.clear();
}

void RdpView::tap(quint32 sc)
{
    m_session->sendKey(true, false, sc);
    m_session->sendKey(false, false, sc);
}

// The server holds the item to paste: optionally click at the drop point, then
// send a clean Ctrl+V with whatever modifiers are held locally lifted remotely.
void RdpView::injectPaste(const QPointF& remotePos, bool click)
{
    if (!m_session)
        return;
    if (click) {
        m_session->sendMouse(PTR_FLAGS_MOVE, remotePos);
        m_session->sendMouse(PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1, remotePos);
        m_session->sendMouse(PTR_FLAGS_BUTTON1, remotePos);
    }
    const bool hadCtrl = m_pressed.contains(RDP_SCANCODE_LCONTROL);
    if (!hadCtrl)
        m_session->sendKey(true, false, RDP_SCANCODE_LCONTROL); // before any Alt release
    const QSet<quint32> held = m_pressed;
    for (quint32 sc : held) {
        if (sc == RDP_SCANCODE_LCONTROL)
            continue;
        m_session->sendKey(false, false, sc);
        m_pressed.remove(sc);
        if (isModifier(sc))
            m_lifted.insert(sc);
    }
    tap(RDP_SCANCODE_KEY_V);
    if (!hadCtrl)
        m_session->sendKey(false, false, RDP_SCANCODE_LCONTROL);
}

void RdpView::releaseAllKeys()
{
    if (m_session)
        for (quint32 sc : std::as_const(m_pressed))
            m_session->sendKey(false, false, sc);
    m_pressed.clear();
    m_lifted.clear();
    m_mappedKeys.clear();
}

void RdpView::focusOutEvent(QFocusEvent* e)
{
    // Avoid stuck modifiers when focus moves to the app chrome.
    releaseAllKeys();
    QQuickItem::focusOutEvent(e);
}

static bool acceptsDrop(const QMimeData* m)
{
    if (m->hasImage())
        return true;
    for (const QUrl& u : m->urls())
        if (u.isLocalFile())
            return true;
    return false;
}

void RdpView::dragEnterEvent(QDragEnterEvent* e)
{
    if (m_session && m_session->state() == RdpSession::Connected && acceptsDrop(e->mimeData()))
        e->acceptProposedAction();
    else
        e->ignore();
}

void RdpView::dragMoveEvent(QDragMoveEvent* e)
{
    if (m_session)
        m_session->sendMouse(PTR_FLAGS_MOVE, toRemote(e->position()));
    e->acceptProposedAction();
}

// Dropped files / images go through the clipboard and are pasted where they
// were dropped (click there, then Ctrl+V).
void RdpView::dropEvent(QDropEvent* e)
{
    if (!m_session || !m_session->clipboard()->dropMime(e->mimeData(), toRemote(e->position()))) {
        e->ignore();
        return;
    }
    forceActiveFocus(Qt::OtherFocusReason);
    e->acceptProposedAction();
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
