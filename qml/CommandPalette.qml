import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import Relay

// ⌘K launcher: fuzzy-search saved hosts, connect to a typed address, run actions.
Popup {
    id: root
    parent: Overlay.overlay
    modal: true
    focus: true
    width: Math.min(620, parent.width - 48)
    x: (parent.width - width) / 2
    y: parent.height * 0.14
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    signal connectHost(string id)
    signal quickConnect(string text)
    signal newHost()
    signal newFolder()
    signal goHome()
    signal toggleTheme()

    function toggle() { opened ? close() : open() }

    property var items: []
    property int current: 0

    function looksLikeAddress(q) {
        return /^(?:(?:[^\\@\s]+\\)?[^@\s]+@)?(\[[^\]]+\]|[A-Za-z0-9._-]+)(?::\d+)?$/.test(q)
            && (q.indexOf(".") >= 0 || q.indexOf(":") >= 0 || q.indexOf("@") >= 0 || /^[A-Za-z0-9-]+$/.test(q))
    }

    function refresh() {
        const q = field.text.trim()
        const out = []
        const hosts = ConnectionStore.search(q, 8)
        const exact = hosts.some(h => h.host.toLowerCase() === q.toLowerCase())
        if (q && looksLikeAddress(q) && !exact)
            out.push({ kind: "connect", title: qsTr("Connect to %1").arg(q), subtitle: qsTr("Quick connect"), icon: "zap", value: q })
        for (const h of hosts)
            out.push({ kind: "host", title: h.name, subtitle: (h.username ? h.username + "@" : "") + h.host + (h.folder ? "  ·  " + h.folder : ""), icon: "monitor", value: h.id })
        const actions = [
            { kind: "action", title: qsTr("New connection"), subtitle: Theme.modLabel + "N", icon: "plus", value: "new" },
            { kind: "action", title: qsTr("New folder"), subtitle: "", icon: "folder-plus", value: "folder" },
            { kind: "action", title: qsTr("Go home"), subtitle: Theme.modLabel + "0", icon: "home", value: "home" },
            { kind: "action", title: Theme.dark ? qsTr("Switch to light theme") : qsTr("Switch to dark theme"), subtitle: "", icon: "refresh", value: "theme" }
        ]
        for (const a of actions)
            if (!q || a.title.toLowerCase().indexOf(q.toLowerCase()) >= 0) out.push(a)
        items = out
        current = 0
    }

    function activate(i) {
        const it = items[i]
        if (!it) return
        close()
        if (it.kind === "connect") quickConnect(it.value)
        else if (it.kind === "host") connectHost(it.value)
        else if (it.value === "new") newHost()
        else if (it.value === "folder") newFolder()
        else if (it.value === "home") goHome()
        else if (it.value === "theme") toggleTheme()
    }

    onAboutToShow: { field.text = ""; refresh() }
    onOpened: field.forceActiveFocus()

    Overlay.modal: Rectangle {
        color: Theme.overlay
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
            NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.slow; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
    }
    exit: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast }
            NumberAnimation { property: "scale"; to: 0.98; duration: Theme.fast }
        }
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
            Icon { name: "search"; size: 18; color: Theme.accent }
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: qsTr("Search connections or type user@host…")
                placeholderTextColor: Theme.textFaint
                color: Theme.text
                font.pixelSize: Theme.fontLg + 1
                background: null
                onTextChanged: root.refresh()
                Keys.onDownPressed: root.current = Math.min(root.items.length - 1, root.current + 1)
                Keys.onUpPressed: root.current = Math.max(0, root.current - 1)
                Keys.onTabPressed: root.current = (root.current + 1) % Math.max(1, root.items.length)
                onAccepted: root.activate(root.current)
            }
            Rectangle {
                implicitWidth: esc.implicitWidth + 12; implicitHeight: 22; radius: 6
                color: Theme.surface2; border.color: Theme.border
                Text { id: esc; anchors.centerIn: parent; text: "esc"; color: Theme.textFaint; font.pixelSize: Theme.fontXs }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        ListView {
            id: results
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 380)
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            clip: true
            model: root.items
            currentIndex: root.current
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 140
            highlightMoveVelocity: -1
            highlight: Item {
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    radius: Theme.radius
                    color: Theme.accentSoft
                    Rectangle {
                        width: 3; height: 18; radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        x: 4
                        color: Theme.accent
                    }
                }
            }

            delegate: AbstractButton {
                id: item
                required property var modelData
                required property int index
                readonly property bool active: index === root.current
                width: results.width
                height: 52
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                onHoveredChanged: if (hovered) root.current = index
                onClicked: root.activate(index)

                // Staggered fade-in on each refresh.
                opacity: 0
                Component.onCompleted: fade.start()
                NumberAnimation { id: fade; target: item; property: "opacity"; to: 1; duration: 160 + item.index * 25 }

                contentItem: RowLayout {
                    spacing: 12
                    Rectangle {
                        Layout.leftMargin: 22
                        width: 30; height: 30; radius: 9
                        color: item.active ? Theme.accent : Theme.surface2
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Icon {
                            anchors.centerIn: parent
                            name: item.modelData.icon
                            size: 15
                            color: item.active ? Theme.accentInk : Theme.textDim
                        }
                    }
                    Column {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            width: parent.width
                            text: item.modelData.title
                            color: Theme.text
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontMd
                            font.weight: item.active ? Font.DemiBold : Font.Medium
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: item.modelData.subtitle
                            color: Theme.textFaint
                            elide: Text.ElideRight
                            font.family: item.modelData.kind === "host" ? Theme.monoFamily : Theme.fontFamily
                            font.pixelSize: Theme.fontSm
                        }
                    }
                    Icon {
                        Layout.rightMargin: 22
                        name: "enter"
                        size: 14
                        color: Theme.accent
                        opacity: item.active ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: results.count === 0
                text: qsTr("No matches")
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
                model: [["↑↓", qsTr("navigate")], ["↵", qsTr("open")], ["esc", qsTr("close")]]
                delegate: Row {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Text { text: modelData[0]; color: Theme.textDim; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold }
                    Text { text: modelData[1]; color: Theme.textFaint; font.pixelSize: Theme.fontXs }
                }
            }
        }
    }
}
