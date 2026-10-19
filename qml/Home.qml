import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Relay

Item {
    id: root
    signal connectHost(string id)
    signal editHost(string id)
    signal quickConnect(string text)
    signal newHost()
    signal openPalette()
    signal toast(string message, string kind)

    property int refreshTick: 0
    readonly property var recents: { root.refreshTick; return ConnectionStore.recent(8) }
    Connections { target: ConnectionStore; function onChanged() { root.refreshTick++ } }

    // Recents split into typed groups (only non-empty groups are shown).
    readonly property var recentGroups: {
        const r = root.recents
        const servers = r.filter(x => x.type === "rdp" || !x.type)
        const dbs = r.filter(x => x.type === "mssql" || x.type === "postgres")
        const out = []
        if (servers.length) out.push({ title: qsTr("Remote desktops"), icon: "monitor",
                                       color: Theme.kindColor("rdp"), items: servers })
        if (dbs.length) out.push({ title: qsTr("Databases"), icon: "database",
                                   color: Theme.kindColor("sql"), items: dbs })
        return out
    }

    function greeting() {
        const h = new Date().getHours()
        return h < 5 ? qsTr("Working late") : h < 12 ? qsTr("Good morning") : h < 18 ? qsTr("Good afternoon") : qsTr("Good evening")
    }
    function ago(ms) {
        if (!ms) return qsTr("Never connected")
        const s = (Date.now() - ms) / 1000
        if (s < 60) return qsTr("Just now")
        if (s < 3600) return qsTr("%1 min ago").arg(Math.floor(s / 60))
        if (s < 86400) return qsTr("%1 h ago").arg(Math.floor(s / 3600))
        return qsTr("%1 d ago").arg(Math.floor(s / 86400))
    }

    Flickable {
        anchors.fill: parent
        contentHeight: content.implicitHeight + 120
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        ColumnLayout {
            id: content
            width: Math.min(760, root.width - 64)
            x: (root.width - width) / 2
            readonly property int gridColumns: width > 620 ? 3 : 2
            y: Math.max(56, (root.height - implicitHeight) * 0.32)
            spacing: 0

            // Entrance: rise and fade.
            opacity: 0
            transform: Translate { id: rise; y: 14 }
            Component.onCompleted: intro.start()
            ParallelAnimation {
                id: intro
                NumberAnimation { target: content; property: "opacity"; to: 1; duration: 420 }
                NumberAnimation { target: rise; property: "y"; to: 0; duration: 520; easing.type: Easing.OutCubic }
            }

            // Greeting on the left, New connection action on the far right.
            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                Text {
                    text: root.greeting()
                    color: Theme.text
                    font.pixelSize: Theme.fontHero
                    font.weight: Font.Bold
                    font.letterSpacing: -0.6
                }
                Item { Layout.fillWidth: true }
                PrimaryButton {
                    Layout.alignment: Qt.AlignVCenter
                    text: qsTr("New connection")
                    iconName: "plus"
                    onClicked: root.newHost()
                }
            }
            Text {
                Layout.topMargin: 6
                Layout.fillWidth: true
                text: root.recents.length > 0
                      ? qsTr("Jump back into a connection below, or press %1K to search.").arg(Theme.modLabel)
                      : qsTr("Add a connection from the sidebar, or press %1K to search.").arg(Theme.modLabel)
                color: Theme.textDim
                font.pixelSize: Theme.fontLg
                wrapMode: Text.WordWrap
            }

            // Recents, grouped by kind (Remote desktops / Databases).
            Repeater {
                model: root.recentGroups
                delegate: ColumnLayout {
                    id: group
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.topMargin: group.index === 0 ? 40 : 28
                    spacing: 12

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text {
                            text: group.modelData.title
                            color: Theme.textDim; font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold; font.letterSpacing: 0.4
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: 1
                            color: Theme.border
                        }
                        Text {
                            visible: group.index === 0
                            text: qsTr("View all  %1K").arg(Theme.modLabel)
                            color: allHover.hovered ? Theme.accent : Theme.textFaint
                            font.pixelSize: Theme.fontSm
                            HoverHandler { id: allHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.openPalette() }
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                        }
                    }

                    GridLayout {
                        id: g
                        Layout.fillWidth: true
                        columns: content.gridColumns
                        columnSpacing: 12
                        rowSpacing: 12
                        readonly property real cell: Math.floor((content.width - columnSpacing * (columns - 1)) / columns)
                        Repeater {
                            model: group.modelData.items
                            delegate: HostCard {
                                required property var modelData
                                required property int index
                                Layout.preferredWidth: g.cell
                                data_: modelData
                                delay: index * 45
                                onClicked: root.connectHost(modelData.id)
                            }
                        }
                    }
                }
            }

            // Shortcut hints
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 36
                spacing: 18
                Repeater {
                    model: [
                        { k: Theme.modLabel + "K", t: qsTr("Search") },
                        { k: Theme.modLabel + "N", t: qsTr("New connection") },
                        { k: Theme.modLabel + "1–9", t: qsTr("Switch tab") },
                        { k: Theme.modLabel + "W", t: qsTr("Close tab") },
                        { k: Theme.modLabel + "↵", t: qsTr("Full screen") }
                    ]
                    delegate: Row {
                        required property var modelData
                        spacing: 6
                        Rectangle {
                            width: kt.implicitWidth + 10; height: 20; radius: 5
                            color: Theme.surface2; border.color: Theme.border
                            Text { id: kt; anchors.centerIn: parent; text: modelData.k; color: Theme.textDim; font.pixelSize: Theme.fontXs; font.weight: Font.Medium }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.t; color: Theme.textFaint; font.pixelSize: Theme.fontSm }
                    }
                }
            }
        }
    }

    component HostCard: AbstractButton {
        id: card
        property var data_
        property int delay: 0
        readonly property bool isSql: card.data_ && (card.data_.type === "mssql" || card.data_.type === "postgres")
        readonly property color kc: card.isSql ? Theme.engineColor(card.data_.type) : Theme.kindColor("rdp")
        implicitHeight: 96
        hoverEnabled: true
        focusPolicy: Qt.NoFocus

        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: cardMenu.popup()
        }
        Menu {
            id: cardMenu
            padding: 6
            background: Rectangle { implicitWidth: 200; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
            enter: Transition { ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
            exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
            delegate: MenuItem {
                id: cmi
                implicitHeight: 30
                readonly property bool danger: text === qsTr("Delete")
                contentItem: Text { leftPadding: 4; text: cmi.text; color: cmi.danger ? Theme.danger : Theme.text
                    font.pixelSize: Theme.fontMd; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: Theme.radiusSm
                    color: cmi.highlighted ? (cmi.danger ? Theme.dangerSoft : Theme.hover) : "transparent" }
            }
            Action { text: qsTr("Connect"); onTriggered: if (card.data_) root.connectHost(card.data_.id) }
            Action { text: qsTr("Edit"); onTriggered: if (card.data_) root.editHost(card.data_.id) }
            MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
            Action {
                text: qsTr("Forget password")
                onTriggered: if (card.data_) { SessionManager.forgetPassword(card.data_.id); root.toast(qsTr("Password forgotten"), "info") }
            }
            Action {
                text: qsTr("Delete")
                onTriggered: if (card.data_) { const n = card.data_.name; ConnectionStore.remove(card.data_.id); root.toast(qsTr("Removed %1").arg(n), "info") }
            }
        }

        opacity: 0
        transform: Translate { id: lift; y: card.hovered && !card.pressed ? -3 : 0
            Behavior on y { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } } }
        scale: pressed ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fast } }
        SequentialAnimation {
            running: true
            PauseAnimation { duration: 120 + card.delay }
            NumberAnimation { target: card; property: "opacity"; to: 1; duration: Theme.slow }
        }

        background: Item {
            RectangularShadow {
                anchors.fill: cbg
                radius: cbg.radius
                blur: card.hovered ? 30 : 12
                offset.y: card.hovered ? 12 : 4
                color: Qt.rgba(0, 0, 0, Theme.dark ? (card.hovered ? 0.5 : 0.3) : (card.hovered ? 0.12 : 0.05))
                Behavior on blur { NumberAnimation { duration: Theme.normal } }
            }
            Rectangle {
                id: cbg
                anchors.fill: parent
                radius: Theme.radiusLg
                color: Theme.surface
                border.color: card.hovered ? Qt.rgba(card.kc.r, card.kc.g, card.kc.b, 0.55) : Theme.border
                Behavior on border.color { ColorAnimation { duration: Theme.normal } }
            }
        }
        contentItem: ColumnLayout {
            spacing: 4
            RowLayout {
                Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 14
                spacing: 10
                Rectangle {
                    width: 30; height: 30; radius: 9
                    color: card.hovered ? card.kc : Qt.rgba(card.kc.r, card.kc.g, card.kc.b, Theme.dark ? 0.16 : 0.12)
                    Behavior on color { ColorAnimation { duration: Theme.normal } }
                    Icon { anchors.centerIn: parent; name: card.isSql ? "database" : "monitor"; size: 15
                        color: card.hovered ? Theme.accentInk : card.kc
                        Behavior on color { ColorAnimation { duration: Theme.normal } } }
                }
                // Type tag so servers vs databases read at a glance.
                Rectangle {
                    implicitWidth: tag.implicitWidth + 14; implicitHeight: 18; radius: 9
                    color: Qt.rgba(card.kc.r, card.kc.g, card.kc.b, Theme.dark ? 0.14 : 0.10)
                    Text {
                        id: tag; anchors.centerIn: parent
                        text: card.isSql ? Theme.engineLabel(card.data_.type) : qsTr("RDP")
                        color: card.kc; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold
                        font.letterSpacing: 0.4
                    }
                }
                Item { Layout.fillWidth: true }
                Icon {
                    name: "arrow-right"; size: 14; color: card.kc
                    opacity: card.hovered ? 1 : 0
                    transform: Translate { x: card.hovered ? 0 : -6; Behavior on x { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } } }
                    Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                }
            }
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
                text: card.data_ ? card.data_.name : ""
                color: Theme.text
                elide: Text.ElideRight
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 12
                text: {
                    if (!card.data_) return ""
                    const who = card.isSql
                        ? (card.data_.database ? card.data_.database + " · " : "")
                        : (card.data_.username ? card.data_.username + "@" : "")
                    return who + card.data_.host + " · " + root.ago(card.data_.lastConnected)
                }
                color: Theme.textFaint
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSm
            }
        }
    }

    component NewCard: AbstractButton {
        id: nc
        implicitHeight: 96
        hoverEnabled: true
        focusPolicy: Qt.NoFocus
        scale: pressed ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fast } }
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.surface
            border.color: nc.hovered ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55) : Theme.border
            Behavior on border.color { ColorAnimation { duration: Theme.normal } }
        }
        contentItem: ColumnLayout {
            spacing: 4
            RowLayout {
                Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 14
                spacing: 10
                Rectangle {
                    width: 30; height: 30; radius: 9
                    color: nc.hovered ? Theme.accent : Theme.accentSoft
                    Behavior on color { ColorAnimation { duration: Theme.normal } }
                    Icon {
                        anchors.centerIn: parent
                        name: "plus"; size: 16
                        color: nc.hovered ? Theme.accentInk : Theme.accent
                        rotation: nc.hovered ? 90 : 0
                        Behavior on rotation { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack } }
                        Behavior on color { ColorAnimation { duration: Theme.normal } }
                    }
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: Theme.modLabel + "N"
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontXs
                    opacity: nc.hovered ? 1 : 0.6
                }
            }
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
                text: qsTr("New connection")
                color: Theme.text
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 12
                text: qsTr("Add a server to connect fast")
                color: Theme.textFaint
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSm
            }
        }
    }
}
