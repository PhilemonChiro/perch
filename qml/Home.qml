import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Relay

Item {
    id: root
    signal connectHost(string id)
    signal quickConnect(string text)
    signal newHost()
    signal openPalette()

    property int refreshTick: 0
    readonly property var recents: { root.refreshTick; return ConnectionStore.recent(6) }
    Connections { target: ConnectionStore; function onChanged() { root.refreshTick++ } }

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

    // Ambient backdrop: two slow-drifting soft glows.
    component Glow: Shape {
        id: glow
        property color tint
        property real strength
        width: 760; height: 760
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: 380; centerY: 380; centerRadius: 380
                focalX: 380; focalY: 380
                GradientStop { position: 0; color: Qt.rgba(glow.tint.r, glow.tint.g, glow.tint.b, glow.strength) }
                GradientStop { position: 1; color: Qt.rgba(glow.tint.r, glow.tint.g, glow.tint.b, 0) }
            }
            PathAngleArc { centerX: 380; centerY: 380; radiusX: 380; radiusY: 380; startAngle: 0; sweepAngle: 360 }
        }
    }
    Glow {
        tint: Theme.accent
        strength: Theme.dark ? 0.28 : 0.16
        x: root.width * 0.1; y: -360
        SequentialAnimation on x {
            loops: Animation.Infinite
            NumberAnimation { to: root.width * 0.3; duration: 14000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.width * 0.05; duration: 14000; easing.type: Easing.InOutSine }
        }
    }
    Glow {
        tint: Theme.accent2
        strength: Theme.dark ? 0.14 : 0.12
        x: root.width * 0.55; y: root.height * 0.4
        SequentialAnimation on y {
            loops: Animation.Infinite
            NumberAnimation { to: root.height * 0.25; duration: 11000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.5; duration: 11000; easing.type: Easing.InOutSine }
        }
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

            Text {
                text: root.greeting()
                color: Theme.text
                font.pixelSize: Theme.fontHero
                font.weight: Font.Bold
                font.letterSpacing: -0.6
            }
            Text {
                Layout.topMargin: 6
                text: qsTr("Where would you like to go?")
                color: Theme.textDim
                font.pixelSize: Theme.fontLg
            }

            // Quick connect bar
            Item {
                id: qc
                Layout.fillWidth: true
                Layout.topMargin: 28
                implicitHeight: 56

                function submit() {
                    const t = qcField.text.trim()
                    if (!t) { shake.restart(); return }
                    root.quickConnect(t)
                    qcField.text = ""
                }

                transform: Translate { id: shakeX }
                SequentialAnimation {
                    id: shake
                    NumberAnimation { target: shakeX; property: "x"; to: -8; duration: 50 }
                    NumberAnimation { target: shakeX; property: "x"; to: 7; duration: 60 }
                    NumberAnimation { target: shakeX; property: "x"; to: -4; duration: 60 }
                    NumberAnimation { target: shakeX; property: "x"; to: 0; duration: 80; easing.type: Easing.OutBack }
                }

                RectangularShadow {
                    anchors.fill: qcBg
                    radius: qcBg.radius
                    blur: qcField.activeFocus ? 40 : 20
                    offset.y: qcField.activeFocus ? 14 : 6
                    color: qcField.activeFocus ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.28) : Qt.rgba(0, 0, 0, Theme.dark ? 0.4 : 0.08)
                    Behavior on blur { NumberAnimation { duration: Theme.slow } }
                    Behavior on color { ColorAnimation { duration: Theme.slow } }
                }
                Rectangle {
                    id: qcBg
                    anchors.fill: parent
                    radius: Theme.radiusLg
                    color: Theme.surface
                    border.color: qcField.activeFocus ? Theme.accent : Theme.border
                    Behavior on border.color { ColorAnimation { duration: Theme.normal } }
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 8
                    spacing: 12
                    Icon {
                        name: "zap"; size: 18
                        color: qcField.activeFocus ? Theme.accent : Theme.textFaint
                        scale: qcField.activeFocus ? 1.1 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
                        Behavior on color { ColorAnimation { duration: Theme.normal } }
                    }
                    TextField {
                        id: qcField
                        Layout.fillWidth: true
                        placeholderText: qsTr("user@host:port")
                        placeholderTextColor: Theme.textFaint
                        color: Theme.text
                        font.family: Theme.monoFamily
                        font.pixelSize: Theme.fontLg
                        background: null
                        onAccepted: qc.submit()
                    }
                    PrimaryButton {
                        text: qsTr("Connect")
                        iconName: "arrow-right"
                        opacity: qcField.text.length ? 1 : 0.55
                        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                        onClicked: qc.submit()
                    }
                }
            }

            // Recents
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 40
                visible: root.recents.length > 0
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Recent")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.4
                }
                Text {
                    text: qsTr("View all  %1K").arg(Theme.modLabel)
                    color: allHover.hovered ? Theme.accent : Theme.textFaint
                    font.pixelSize: Theme.fontSm
                    HoverHandler { id: allHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.openPalette() }
                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                }
            }

            GridLayout {
                id: grid
                Layout.fillWidth: true
                Layout.topMargin: 12
                columns: content.width > 620 ? 3 : 2
                columnSpacing: 12
                rowSpacing: 12
                readonly property real cell: Math.floor((content.width - columnSpacing * (columns - 1)) / columns)

                Repeater {
                    model: root.recents
                    delegate: HostCard {
                        required property var modelData
                        required property int index
                        Layout.preferredWidth: grid.cell
                        data_: modelData
                        delay: index * 45
                        onClicked: root.connectHost(modelData.id)
                    }
                }
                NewCard {
                    Layout.preferredWidth: grid.cell
                    onClicked: root.newHost()
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
        implicitHeight: 96
        hoverEnabled: true
        focusPolicy: Qt.NoFocus

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
                border.color: card.hovered ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55) : Theme.border
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
                    color: card.hovered ? Theme.accent : Theme.accentSoft
                    Behavior on color { ColorAnimation { duration: Theme.normal } }
                    Icon { anchors.centerIn: parent; name: "monitor"; size: 15; color: card.hovered ? Theme.accentInk : Theme.accent
                        Behavior on color { ColorAnimation { duration: Theme.normal } } }
                }
                Item { Layout.fillWidth: true }
                Icon {
                    name: "arrow-right"; size: 14; color: Theme.accent
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
                text: card.data_ ? ((card.data_.username ? card.data_.username + "@" : "") + card.data_.host + " · " + root.ago(card.data_.lastConnected)) : ""
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
            color: nc.hovered ? Theme.accentSoft : "transparent"
            border.color: nc.hovered ? Theme.accent : Theme.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.normal } }
            Behavior on border.color { ColorAnimation { duration: Theme.normal } }
        }
        contentItem: Column {
            spacing: 8
            anchors.centerIn: parent
            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "plus"; size: 18
                color: nc.hovered ? Theme.accent : Theme.textDim
                rotation: nc.hovered ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack } }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("New connection")
                color: nc.hovered ? Theme.accent : Theme.textDim
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }
        }
    }
}
