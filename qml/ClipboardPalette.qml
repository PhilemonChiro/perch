import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import Relay

// ⌘⇧V clipboard history: the last items copied on either side (in memory only).
// Type to filter, ↑↓ to choose, ↵ pastes into the server, ⌥↵ pastes as plain text.
Popup {
    id: root
    parent: Overlay.overlay
    modal: true
    focus: true
    width: Math.min(600, parent.width - 48)
    x: (parent.width - width) / 2
    y: parent.height * 0.14
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property var board        // RdpClipboard of the session to paste into
    property string serverName
    property var items: []
    property int current: 0
    readonly property bool reduce: ClipHistory.reduceMotion

    function toggle() { opened ? close() : open() }
    function refresh() {
        const q = field.text.trim().toLowerCase()
        items = ClipHistory.items.filter(it => !q || it.search.indexOf(q) >= 0)
        current = Math.min(current, Math.max(0, items.length - 1))
    }
    function activate(i, plain) {
        const it = items[i]
        if (!it || !board) return
        close()
        board.pasteHistory(it.id, plain)
    }
    function ago(ms) {
        const s = Math.max(0, (Date.now() - ms) / 1000)
        if (s < 45) return qsTr("now")
        if (s < 3600) return qsTr("%1 min").arg(Math.round(s / 60))
        if (s < 86400) return qsTr("%1 h").arg(Math.round(s / 3600))
        return Qt.formatDateTime(new Date(ms), "d MMM")
    }

    Connections { target: ClipHistory; function onChanged() { if (root.opened) root.refresh() } }

    onAboutToShow: { field.text = ""; current = 0; refresh() }
    onOpened: field.forceActiveFocus()

    Overlay.modal: Rectangle { color: Theme.overlay }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
            NumberAnimation { property: "scale"; from: root.reduce ? 1 : 0.96; to: 1; duration: Theme.slow; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast }
    }

    background: Item {
        RectangularShadow {
            anchors.fill: bg
            radius: bg.radius
            blur: 48
            offset.y: 20
            color: Qt.rgba(0, 0, 0, Theme.dark ? 0.6 : 0.2)
        }
        Rectangle {
            id: bg
            anchors.fill: parent
            radius: Theme.radiusXl
            color: Theme.surface
            border.color: Theme.borderStrong
        }
    }

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 58
            Layout.leftMargin: 20
            Layout.rightMargin: 16
            spacing: 12
            Icon { name: "clipboard"; size: 18; color: Theme.accent }
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: qsTr("Search clipboard history…")
                placeholderTextColor: Theme.textFaint
                color: Theme.text
                font.pixelSize: Theme.fontLg + 1
                background: null
                onTextChanged: root.refresh()
                Keys.onDownPressed: root.current = Math.min(root.items.length - 1, root.current + 1)
                Keys.onUpPressed: root.current = Math.max(0, root.current - 1)
                Keys.onReturnPressed: event => root.activate(root.current, (event.modifiers & Qt.AltModifier) !== 0)
                Keys.onEnterPressed: event => root.activate(root.current, (event.modifiers & Qt.AltModifier) !== 0)
            }
            Text {
                text: root.serverName ? qsTr("into %1").arg(root.serverName) : ""
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
                elide: Text.ElideRight
                Layout.maximumWidth: 160
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: count ? Math.min(contentHeight, 420) : 96
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            clip: true
            model: root.items
            currentIndex: root.current
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: root.reduce ? 0 : 140
            highlightMoveVelocity: -1
            highlight: Item {
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    radius: Theme.radius
                    color: Theme.accentSoft
                }
            }

            delegate: AbstractButton {
                id: row
                required property var modelData
                required property int index
                readonly property bool active: index === root.current
                readonly property bool fromServer: modelData.source === "server"
                width: list.width
                height: 58
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                onHoveredChanged: if (hovered) root.current = index
                onClicked: root.activate(index, false)

                contentItem: RowLayout {
                    spacing: 12
                    Rectangle {
                        Layout.leftMargin: 22
                        width: 38; height: 38; radius: 9
                        color: row.active ? Theme.surface : Theme.surface2
                        border.color: Theme.border
                        clip: true
                        Image {
                            id: th
                            anchors.fill: parent
                            visible: !!row.modelData.thumb
                            source: row.modelData.thumb || ""
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                        }
                        Icon {
                            anchors.centerIn: parent
                            visible: !th.visible
                            size: 16
                            color: Theme.textDim
                            name: row.modelData.kind === "files" ? "file" : row.modelData.kind === "image" ? "image" : "text"
                        }
                    }
                    Column {
                        Layout.fillWidth: true
                        spacing: 3
                        Text {
                            width: parent.width
                            text: row.modelData.title
                            color: Theme.text
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontMd
                            font.weight: row.active ? Font.DemiBold : Font.Medium
                        }
                        Text {
                            width: parent.width
                            text: row.modelData.kind === "files" && row.modelData.names
                                  ? row.modelData.names.join(", ") + (row.modelData.detail ? "  ·  " + row.modelData.detail : "")
                                  : row.modelData.detail
                            color: Theme.textFaint
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSm
                        }
                    }
                    Rectangle {
                        implicitWidth: Math.min(src.implicitWidth + 12, 130)
                        implicitHeight: 18
                        radius: 5
                        color: row.fromServer ? Theme.accentSoft : Theme.surface2
                        Text {
                            id: src
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, 118)
                            elide: Text.ElideRight
                            text: row.modelData.origin
                            color: row.fromServer ? Theme.accent : Theme.textDim
                            font.pixelSize: Theme.fontXs - 1
                            font.weight: Font.DemiBold
                        }
                    }
                    Text {
                        Layout.rightMargin: 22
                        Layout.preferredWidth: 44
                        horizontalAlignment: Text.AlignRight
                        text: root.ago(row.modelData.time)
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: ClipHistory.items.length ? qsTr("No matches") : qsTr("Copy something on your Mac or the server — it shows up here")
                color: Theme.textFaint
                font.pixelSize: Theme.fontMd
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        Row {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            Layout.leftMargin: 20
            spacing: 18
            Repeater {
                model: [["↑↓", qsTr("navigate")], ["↵", qsTr("paste")], [Theme.mac ? "⌥↵" : "Alt+↵", qsTr("paste as plain text")], ["esc", qsTr("close")]]
                delegate: Row {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Text { text: modelData[0]; color: Theme.textDim; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold }
                    Text { text: modelData[1]; color: Theme.textFaint; font.pixelSize: Theme.fontXs }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Kept in memory only")
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
                opacity: 0.8
            }
        }
    }
}
