#pragma once

#include <QPointer>
#include <QQuickItem>
#include <QSet>
#include <QTimer>

#include "RdpSession.h"

// Renders a session's framebuffer as a scene-graph texture and forwards
// mouse/keyboard input to it in remote desktop coordinates.
class RdpView : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(RdpSession* session READ session WRITE setSession NOTIFY sessionChanged)

public:
    explicit RdpView(QQuickItem* parent = nullptr);

    RdpSession* session() const { return m_session; }
    void setSession(RdpSession* s);

signals:
    void sessionChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData& value) override;
    bool event(QEvent* e) override;
    void keyPressEvent(QKeyEvent* e) override;
    void keyReleaseEvent(QKeyEvent* e) override;
    void mousePressEvent(QMouseEvent* e) override;
    void mouseReleaseEvent(QMouseEvent* e) override;
    void mouseMoveEvent(QMouseEvent* e) override;
    void hoverMoveEvent(QHoverEvent* e) override;
    void wheelEvent(QWheelEvent* e) override;
    void focusOutEvent(QFocusEvent* e) override;

private:
    QRectF targetRect() const;
    QPointF toRemote(const QPointF& p) const;
    void pushViewport();
    void releaseAllKeys();

    QPointer<RdpSession> m_session;
    bool m_dirty = true;
    QTimer m_resizeDebounce;
    QSet<quint32> m_pressed;
    int m_wheelAccumY = 0;
    int m_wheelAccumX = 0;
};
