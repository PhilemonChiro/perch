import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Relay

// Clipboard capsule: a near-invisible pill at the top of the remote view that
// springs open on clipboard activity (direction, preview, transfer progress),
// then settles back. Hover re-opens it; click picks the sync mode.
Item {
    id: root
    property var board            // RdpClipboard
    property string serverName
    property bool live: false
    signal openHistory()
    signal returnFocus()

    readonly property bool reduce: ClipHistory.reduceMotion
    readonly property var act: board ? board.activity : ({})
    readonly property bool busy: board ? board.busy : false
    readonly property int mode: board ? board.mode : 0
    readonly property bool off: board && (board.unavailable || mode === RdpClipboard.Off)
    readonly property bool hovered: hover.hovered
    readonly property bool expanded: live && (showing.running || hovered || busy || modeMenu.opened)
    // What the open capsule shows: a transfer, the last activity, or the sync status.
    readonly property string view: busy ? "transfer" : (showing.running && act.kind) ? "activity" : "status"
    readonly property string localName: Theme.mac ? qsTr("Mac") : qsTr("This PC")
    readonly property var modeNames: [qsTr("Both ways"), qsTr("Mac → Server only"),
                                      qsTr("Server → Mac only"), qsTr("Off")]

    implicitWidth: capsule.width
    implicitHeight: capsule.height
    width: capsule.width
    height: capsule.height
    visible: live

    Timer { id: showing; interval: root.act.kind === "error" || root.act.action ? 4200 : 2600 }
    Connections {
        target: root.board
        function onActivityChanged() { if (root.live) showing.restart() }
    }

    // Larger invisible hover target so the thin idle pill is easy to find.
    Item {
        anchors.horizontalCenter: capsule.horizontalCenter
        anchors.top: capsule.top
        width: Math.max(capsule.width, 140)
        height: Math.max(capsule.height, 22)
        HoverHandler { id: hover }
    }

    RectangularShadow {
        anchors.fill: capsule
        radius: capsule.radius
        visible: root.expanded
        opacity: content.opacity
        blur: 28; offset.y: 8; spread: 0
        color: Qt.rgba(0, 0, 0, Theme.dark ? 0.55 : 0.18)
    }

    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        readonly property real idleW: root.off || root.mode !== RdpClipboard.Both ? 30 : 38
        readonly property real idleH: root.off || root.mode !== RdpClipboard.Both ? 16 : 6
        width: root.expanded ? Math.min(content.implicitWidth + 28, root.parent ? root.parent.width - 32 : 480) : idleW
        height: root.expanded ? 48 : idleH
        radius: height / 2
        color: root.expanded ? Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.98)
                             : Qt.rgba(Theme.surface3.r, Theme.surface3.g, Theme.surface3.b, 0.9)
        border.color: root.expanded ? Theme.borderStrong : "transparent"
        opacity: root.expanded ? 1 : (root.hovered ? 0.9 : (root.off || root.mode !== RdpClipboard.Both ? 0.55 : 0.32))
        clip: true

        Behavior on width { enabled: !root.reduce; SpringAnimation { spring: 4; damping: 0.36; epsilon: 0.3 } }
        Behavior on height { enabled: !root.reduce; SpringAnimation { spring: 4.5; damping: 0.4; epsilon: 0.3 } }
        Behavior on opacity { enabled: !root.reduce; NumberAnimation { duration: Theme.normal } }
        Behavior on color { enabled: !root.reduce; ColorAnimation { duration: Theme.fast } }

        // Idle glyph for a one-way / off / unavailable clipboard.
        Icon {
            anchors.centerIn: parent
            visible: !root.expanded && (root.off || root.mode !== RdpClipboard.Both)
            name: root.board && root.board.unavailable ? "alert" : root.mode === RdpClipboard.Off ? "x" : "arrow-right"
            size: 10
            color: Theme.textDim
            rotation: root.mode === RdpClipboard.ToMac ? 180 : 0
        }

        TapHandler {
            // The action pill and the ring handle their own taps.
            enabled: root.view !== "transfer" && !actionHover.hovered && !cancelHover.hovered
            onTapped: modeMenu.popup(capsule, (capsule.width - 240) / 2, capsule.height + 6)
        }

        RowLayout {
            id: content
            anchors.verticalCenter: parent.verticalCenter
            x: 14
            spacing: 10
            opacity: root.expanded ? 1 : 0
            Behavior on opacity { enabled: !root.reduce; NumberAnimation { duration: root.expanded ? Theme.slow : 80 } }

            // Direction: [Mac] -> [server] or [server] -> [Mac]
            Row {
                visible: root.view !== "status" || root.mode !== RdpClipboard.Off
                spacing: 4
                readonly property bool toMac: root.view === "transfer" ? root.board.transferDir === "toMac"
                                            : root.view === "activity" ? root.act.dir === "toMac"
                                            : root.mode === RdpClipboard.ToMac
                readonly property bool oneWay: root.view === "status" && root.mode !== RdpClipboard.Both
                Badge { text: parent.toMac ? root.serverName : root.localName }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "arrow-right"; size: 11
                    color: root.act.kind === "error" && root.view === "activity" ? Theme.danger
                         : root.act.kind === "concealed" && root.view === "activity" ? Theme.warning : Theme.accent
                    opacity: parent.oneWay ? 0.5 : 1
                }
                Badge { text: parent.toMac ? root.localName : root.serverName }
            }

            Rectangle { width: 1; height: 22; color: Theme.border }

            // Preview: thumbnail / file / text icon + title + detail. Drag it out to
            // save the server's item (image -> PNG file, files, or text).
            Item {
                id: preview
                implicitWidth: previewRow.implicitWidth
                implicitHeight: previewRow.implicitHeight
                readonly property bool draggable: root.view === "activity" && root.act.dir === "toMac"
                                                  && root.board.hasServerItem
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction
                DragHandler {
                    id: dragOut
                    enabled: preview.draggable
                    target: null
                    onActiveChanged: {
                        if (active) {
                            preview.Drag.mimeData = root.board.dragData()
                            preview.Drag.active = true
                        } else {
                            preview.Drag.active = false
                        }
                    }
                }
                HoverHandler { cursorShape: preview.draggable ? Qt.OpenHandCursor : Qt.ArrowCursor }

                RowLayout {
                    id: previewRow
                    spacing: 9
                    Rectangle {
                        visible: root.view !== "transfer"
                        width: 30; height: 30; radius: 8
                        color: Theme.surface3
                        clip: true
                        Image {
                            id: thumb
                            anchors.fill: parent
                            visible: root.view === "activity" && !!root.act.thumb
                            source: visible ? root.act.thumb : ""
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                        }
                        Icon {
                            anchors.centerIn: parent
                            visible: !thumb.visible
                            size: 15
                            color: root.act.kind === "error" && root.view === "activity" ? Theme.danger : Theme.textDim
                            name: root.view === "status" ? "clipboard"
                                : root.act.kind === "files" ? "file"
                                : root.act.kind === "image" ? "image"
                                : root.act.kind === "concealed" ? "lock"
                                : root.act.kind === "error" ? "alert"
                                : root.act.kind === "info" ? "clipboard" : "text"
                        }
                    }
                    // Transfer progress ring; click to cancel.
                    Item {
                        visible: root.view === "transfer"
                        width: 30; height: 30
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                strokeColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                strokeWidth: 3; fillColor: "transparent"
                                PathAngleArc { centerX: 15; centerY: 15; radiusX: 13; radiusY: 13; startAngle: 0; sweepAngle: 360 }
                            }
                            ShapePath {
                                strokeColor: Theme.accent
                                strokeWidth: 3; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                PathAngleArc {
                                    centerX: 15; centerY: 15; radiusX: 13; radiusY: 13; startAngle: -90
                                    sweepAngle: Math.max(4, 360 * (root.board ? root.board.progress : 0))
                                    Behavior on sweepAngle { enabled: !root.reduce; NumberAnimation { duration: 160 } }
                                }
                            }
                        }
                        Icon {
                            anchors.centerIn: parent
                            name: "x"; size: 11
                            color: cancelHover.hovered ? Theme.danger : Theme.textDim
                        }
                        HoverHandler { id: cancelHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.board.cancelTransfer() }
                    }
                    Column {
                        spacing: 1
                        Text {
                            width: Math.min(implicitWidth, 260)
                            elide: Text.ElideRight
                            color: Theme.text
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold
                            text: root.view === "transfer" ? root.board.transferText
                                : root.view === "activity" ? (root.act.title || "")
                                : root.board && root.board.unavailable ? qsTr("Clipboard sharing is off on this server")
                                : qsTr("Clipboard · %1").arg(root.modeNames[root.mode])
                        }
                        Text {
                            width: Math.min(implicitWidth, 260)
                            elide: Text.ElideRight
                            visible: text !== ""
                            color: root.act.kind === "error" && root.view === "activity" ? Theme.danger : Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            text: root.view === "transfer" ? qsTr("%1% · click the ring to cancel").arg(Math.round(root.board.progress * 100))
                                : root.view === "activity" ? (root.act.detail || "")
                                : qsTr("%1⇧V for history · click to change").arg(Theme.modLabel)
                        }
                    }
                }
            }

            // Follow-up action: reveal saved files, or fetch a large file list.
            Rectangle {
                visible: root.view === "activity" && !!root.act.action
                Layout.leftMargin: 2
                implicitWidth: actionText.implicitWidth + 20
                implicitHeight: 26
                radius: 13
                color: actionHover.hovered ? Theme.accent : Theme.accentSoft
                Behavior on color { ColorAnimation { duration: Theme.fast } }
                Text {
                    id: actionText
                    anchors.centerIn: parent
                    text: root.act.action === "download" ? qsTr("Download") : qsTr("Show in Finder")
                    color: actionHover.hovered ? Theme.accentInk : Theme.accent
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        if (root.act.action === "download") root.board.download()
                        else root.board.reveal()
                        showing.stop()
                    }
                }
            }
        }
    }

    component Badge: Rectangle {
        property alias text: label.text
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        implicitWidth: Math.min(label.implicitWidth + 12, 120)
        implicitHeight: 18
        width: implicitWidth
        height: implicitHeight
        radius: 5
        color: Theme.surface3
        Text {
            id: label
            anchors.centerIn: parent
            width: Math.min(implicitWidth, 108)
            elide: Text.ElideRight
            color: Theme.textDim
            font.pixelSize: Theme.fontXs - 1
            font.weight: Font.DemiBold
        }
    }

    Menu {
        id: modeMenu
        padding: 6
        onClosed: root.returnFocus()
        background: Rectangle { implicitWidth: 240; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
            NumberAnimation { property: "scale"; from: root.reduce ? 1 : 0.95; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
        delegate: MenuItem {
            id: mi
            implicitHeight: 30
            contentItem: RowLayout {
                spacing: 8
                Icon { Layout.leftMargin: 2; name: "check"; size: 12; color: Theme.accent; opacity: mi.text === root.modeNames[root.mode] ? 1 : 0 }
                Text {
                    Layout.fillWidth: true
                    text: mi.text
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                }
            }
            background: Rectangle { radius: Theme.radiusSm; color: mi.highlighted ? Theme.hover : "transparent" }
        }
        Action { text: root.modeNames[0]; onTriggered: root.board.mode = RdpClipboard.Both }
        Action { text: root.modeNames[1]; onTriggered: root.board.mode = RdpClipboard.ToServer }
        Action { text: root.modeNames[2]; onTriggered: root.board.mode = RdpClipboard.ToMac }
        Action { text: root.modeNames[3]; onTriggered: root.board.mode = RdpClipboard.Off }
        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
        Action { text: qsTr("Clipboard history…  %1⇧V").arg(Theme.modLabel); onTriggered: root.openHistory() }
    }
}
