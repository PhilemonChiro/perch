import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

Rectangle {
    id: root
    color: Theme.sidebar

    signal connectHost(string id)
    signal editHost(string id)
    signal newHost(string folderId)
    signal openPalette()
    signal manageCredentials()
    signal addCredential()
    signal collapse()
    signal toast(string message, string kind)

    ColumnLayout {
        width: 268
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        spacing: 0

        // Brand
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 14
            Layout.leftMargin: 16
            Layout.rightMargin: 10
            spacing: 10

            Icon {
                id: mark
                name: "brand"
                color: Theme.text
                size: 30
                scale: brandHover.hovered ? 1.07 : 1
                Behavior on scale { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack } }
                HoverHandler { id: brandHover }
            }
            Text {
                text: "Perch"
                color: Theme.text
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
                font.letterSpacing: -0.2
            }
            Item { Layout.fillWidth: true }
            IconButton { iconName: "sidebar"; tip: qsTr("Hide sidebar  %1B").arg(Theme.modLabel); onClicked: root.collapse() }
        }

        // Search / quick connect launcher
        AbstractButton {
            id: searchBtn
            Layout.fillWidth: true
            Layout.margins: 12
            Layout.topMargin: 16
            implicitHeight: 36
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            onClicked: root.openPalette()
            scale: pressed ? 0.98 : 1
            Behavior on scale { NumberAnimation { duration: Theme.fast } }
            background: Rectangle {
                radius: Theme.radius
                color: searchBtn.hovered ? Theme.surface2 : Theme.surface
                border.color: searchBtn.hovered ? Theme.borderStrong : Theme.border
                Behavior on color { ColorAnimation { duration: Theme.fast } }
            }
            contentItem: RowLayout {
                spacing: 8
                Icon { Layout.leftMargin: 10; name: "search"; size: 14; color: Theme.textFaint }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Search or connect…")
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontMd
                }
                Rectangle {
                    Layout.rightMargin: 8
                    implicitWidth: kbd.implicitWidth + 10
                    implicitHeight: 20
                    radius: 5
                    color: Theme.surface3
                    Text {
                        id: kbd
                        anchors.centerIn: parent
                        text: Theme.modLabel + "K"
                        color: Theme.textDim
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Medium
                    }
                }
            }
        }

        // Section header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 18
            Layout.rightMargin: 10
            Layout.topMargin: 4
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: qsTr("CONNECTIONS")
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }
            IconButton {
                iconName: "folder-plus"; iconSize: 14; implicitWidth: 26; implicitHeight: 26
                tip: qsTr("New folder")
                onClicked: {
                    const id = ConnectionStore.addFolder(qsTr("New folder"), "")
                    list.pendingRename = id
                }
            }
            IconButton {
                iconName: "plus"; iconSize: 15; implicitWidth: 26; implicitHeight: 26
                tip: qsTr("New connection  %1N").arg(Theme.modLabel)
                onClicked: root.newHost("")
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 6
            clip: true
            model: ConnectionStore
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds
            property string pendingRename: ""

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                contentItem: Rectangle { implicitWidth: 4; radius: 2; color: Theme.borderStrong; opacity: parent.active ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.normal } } }
            }

            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
                    NumberAnimation { property: "x"; from: -10; to: 0; duration: Theme.slow; easing.type: Theme.easing }
                }
            }
            remove: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast }
                    NumberAnimation { property: "x"; to: -10; duration: Theme.fast }
                }
            }
            displaced: Transition { NumberAnimation { properties: "y"; duration: Theme.normal; easing.type: Theme.easing } }

            delegate: TreeRow {
                width: list.width
                onActivated: kind === "folder" ? ConnectionStore.toggle(itemId) : root.connectHost(itemId)
                onEdit: kind === "host" ? root.editHost(itemId) : startRename()
                onAddChild: root.newHost(itemId)
                onRemoveItem: {
                    const label = name
                    ConnectionStore.remove(itemId)
                    root.toast(qsTr("Removed %1").arg(label), "info")
                }
                onForget: { SessionManager.forgetPassword(itemId); root.toast(qsTr("Password forgotten"), "info") }
                Component.onCompleted: if (itemId === list.pendingRename) { list.pendingRename = ""; startRename() }
            }

            // Empty state
            Column {
                anchors.centerIn: parent
                width: parent.width - 48
                spacing: 12
                visible: list.count === 0
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.slow } }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 44; height: 44; radius: 12
                    color: Theme.accentSoft
                    Icon { anchors.centerIn: parent; name: "monitor"; size: 20; color: Theme.accent }
                    SequentialAnimation on y {
                        loops: Animation.Infinite
                        running: list.count === 0
                        NumberAnimation { to: -3; duration: 1400; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0; duration: 1400; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("No saved connections yet")
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Save hosts here to connect in one click. Passwords stay in your system keychain.")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    lineHeight: 1.3
                }
                GhostButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    iconName: "plus"
                    text: qsTr("Add connection")
                    onClicked: root.newHost("")
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            height: 1
            color: Theme.border
        }

        // Section header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 18; Layout.rightMargin: 10
            Layout.topMargin: 12
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: qsTr("CREDENTIALS")
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }
            IconButton {
                iconName: "plus"; iconSize: 15; implicitWidth: 26; implicitHeight: 26
                tip: qsTr("New credential")
                onClicked: root.addCredential()
            }
        }

        // Credentials — reusable sign-ins kept in the system keychain.
        AbstractButton {
            id: credBtn
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 6
            implicitHeight: 40
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            onClicked: root.manageCredentials()
            scale: pressed ? 0.98 : 1
            Behavior on scale { NumberAnimation { duration: Theme.fast } }
            background: Rectangle {
                radius: Theme.radius
                color: credBtn.hovered ? Theme.surface2 : "transparent"
                border.color: credBtn.hovered ? Theme.border : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fast } }
            }
            contentItem: RowLayout {
                spacing: 10
                Rectangle {
                    Layout.leftMargin: 6
                    width: 28; height: 28; radius: 9
                    color: Theme.accentSoft
                    Icon { anchors.centerIn: parent; name: "lock"; size: 14; color: Theme.accent }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 0
                    Text { text: qsTr("Credentials manager"); color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.Medium }
                    Text {
                        text: CredentialStore.count === 1 ? qsTr("1 saved sign-in") : qsTr("%1 saved sign-ins").arg(CredentialStore.count)
                        color: Theme.textFaint; font.pixelSize: Theme.fontXs
                    }
                }
                Icon { Layout.rightMargin: 10; name: "chevron"; size: 12; color: Theme.textFaint }
            }
        }

        // Footer
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            Layout.topMargin: 8; Layout.bottomMargin: 12
            spacing: 6
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                text: ConnectionStore.hostCount === 1 ? qsTr("1 host") : qsTr("%1 hosts").arg(ConnectionStore.hostCount)
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
            }
            AbstractButton {
                id: themeBtn
                implicitWidth: 52; implicitHeight: 24
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                onClicked: Theme.mode = Theme.dark ? "light" : "dark"
                background: Rectangle {
                    radius: 12
                    color: Theme.surface2
                    border.color: themeBtn.hovered ? Theme.borderStrong : Theme.border
                }
                contentItem: Item {
                    Rectangle {
                        width: 20; height: 20; radius: 10
                        y: 2
                        x: Theme.dark ? 2 : themeBtn.width - width - 2
                        color: Theme.dark ? Theme.surface3 : "#FFD166"
                        Behavior on x { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack } }
                        Behavior on color { ColorAnimation { duration: Theme.slow } }
                        // Crescent cut-out for dark mode.
                        Rectangle {
                            width: 14; height: 14; radius: 7
                            x: Theme.dark ? 8 : 22; y: -2
                            color: Theme.surface2
                            Behavior on x { NumberAnimation { duration: Theme.slow; easing.type: Theme.easing } }
                        }
                        clip: true
                    }
                }
            }
        }
    }

    component TreeRow: AbstractButton {
        id: row
        required property string itemId
        required property string kind
        required property string name
        required property int depth
        required property bool expanded
        required property int childCount
        required property string host
        required property string username

        signal activated()
        signal edit()
        signal addChild()
        signal removeItem()
        signal forget()

        readonly property bool isFolder: kind === "folder"
        property bool renaming: false
        readonly property int sessionIndex: { SessionManager.count; return isFolder ? -1 : SessionManager.indexOfHost(itemId) }
        readonly property var session: sessionIndex >= 0 ? SessionManager.at(sessionIndex) : null

        function startRename() { renaming = true; renameField.text = name; renameField.forceActiveFocus(); renameField.selectAll() }

        implicitHeight: 32
        hoverEnabled: true
        focusPolicy: Qt.NoFocus
        onClicked: if (!renaming) activated()

        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: menu.popup()
        }

        background: Item {
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Theme.radiusSm + 1
                color: row.pressed ? Theme.surface3 : row.hovered ? Theme.surface2 : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fast } }
            }
            // Active-session marker grows in from the edge.
            Rectangle {
                x: 2
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: row.session ? 16 : 0
                radius: 2
                color: Theme.stateColor(row.session ? row.session.state : 0)
                Behavior on height { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutBack } }
                Behavior on color { ColorAnimation { duration: Theme.slow } }
            }
        }

        contentItem: RowLayout {
            spacing: 8
            Item { Layout.preferredWidth: 10 + row.depth * 14 }
            Icon {
                visible: row.isFolder
                name: "chevron"
                size: 12
                color: Theme.textFaint
                rotation: row.expanded ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
            }
            Icon {
                name: row.isFolder ? "folder" : "monitor"
                size: 15
                color: row.isFolder ? Theme.textDim : (row.hovered ? Theme.accent : Theme.textDim)
                Behavior on color { ColorAnimation { duration: Theme.fast } }
            }
            Text {
                visible: !row.renaming
                Layout.fillWidth: true
                text: row.name
                color: Theme.text
                elide: Text.ElideRight
                font.pixelSize: Theme.fontMd
                font.weight: row.isFolder ? Font.Medium : Font.Normal
            }
            TextField {
                id: renameField
                visible: row.renaming
                Layout.fillWidth: true
                implicitHeight: 24
                padding: 4
                color: Theme.text
                font.pixelSize: Theme.fontMd
                background: Rectangle { radius: 5; color: Theme.surface; border.color: Theme.accent }
                onAccepted: { ConnectionStore.renameFolder(row.itemId, text); row.renaming = false }
                onActiveFocusChanged: if (!activeFocus && row.renaming) { ConnectionStore.renameFolder(row.itemId, text); row.renaming = false }
                Keys.onEscapePressed: row.renaming = false
            }
            Text {
                visible: row.isFolder && !row.hovered && !row.renaming
                text: row.childCount
                color: Theme.textFaint
                font.pixelSize: Theme.fontXs
                Layout.rightMargin: 16
            }
            StatusDot {
                visible: !row.isFolder && row.session !== null && !row.hovered
                state: row.session ? row.session.state : 0
                Layout.rightMargin: 18
            }
            Row {
                visible: row.hovered && !row.renaming
                Layout.rightMargin: 12
                spacing: 0
                IconButton {
                    visible: row.isFolder
                    iconName: "plus"; iconSize: 13; implicitWidth: 24; implicitHeight: 24
                    tip: qsTr("Add connection here")
                    onClicked: row.addChild()
                }
                IconButton {
                    iconName: "pencil"; iconSize: 13; implicitWidth: 24; implicitHeight: 24
                    tip: row.isFolder ? qsTr("Rename") : qsTr("Edit")
                    onClicked: row.edit()
                }
            }
        }

        Menu {
            id: menu
            padding: 6
            background: Rectangle { implicitWidth: 200; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
            enter: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                    NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: Theme.normal; easing.type: Theme.easing }
                }
            }
            exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
            delegate: MenuItem {
                id: mi
                implicitHeight: 30
                property bool danger: text === qsTr("Delete")
                contentItem: Text {
                    leftPadding: 4
                    text: mi.text
                    color: mi.danger ? Theme.danger : Theme.text
                    font.pixelSize: Theme.fontMd
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: mi.highlighted ? (mi.danger ? Theme.dangerSoft : Theme.surface3) : "transparent"
                }
            }
            Action { text: row.isFolder ? (row.expanded ? qsTr("Collapse") : qsTr("Expand")) : qsTr("Connect"); onTriggered: row.activated() }
            Action { text: row.isFolder ? qsTr("Rename") : qsTr("Edit"); onTriggered: row.edit() }
            Action { text: qsTr("New connection here"); enabled: row.isFolder; onTriggered: row.addChild() }
            Action { text: qsTr("Forget password"); enabled: !row.isFolder; onTriggered: row.forget() }
            MenuSeparator {
                contentItem: Rectangle { implicitHeight: 1; color: Theme.border }
            }
            Action { text: qsTr("Delete"); onTriggered: row.removeItem() }
        }
    }
}
