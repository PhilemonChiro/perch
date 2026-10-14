import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import Relay

// Slide-over sheet for creating and editing saved connections.
Popup {
    id: root
    parent: Overlay.overlay
    modal: true
    focus: true
    width: Math.min(440, parent.width)
    height: parent.height
    x: parent.width - width
    y: 0
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside


    signal saved(string name, bool connect, string id)
    signal deleted(string name)

    property string editId: ""
    property string folderId: ""
    readonly property bool editing: editId !== ""
    property string sharePath: ""
    property string credentialId: ""
    signal manageCredentials(bool addNew)

    function reset() {
        nameF.text = ""; hostF.text = ""; portF.text = "3389"; gatewayF.text = ""
        udpSwitch.checked = false
        sharePath = ""
        credentialId = ""
        folderId = ""
        hostF.error = false
    }
    function openNew(folder) {
        editId = ""; reset(); folderId = folder || ""; open()
    }
    function openEdit(id) {
        const h = ConnectionStore.host(id)
        if (!h.id) return
        editId = id; reset()
        nameF.text = h.name === h.host ? "" : h.name
        hostF.text = h.host; portF.text = String(h.port)
        gatewayF.text = h.gateway || ""
        udpSwitch.checked = h.useUdp || false
        sharePath = h.share || ""
        credentialId = h.credentialId || ""
        folderId = h.folderId || ""
        open()
    }
    function openFromSession(s) {
        editId = ""; reset()
        hostF.text = s.host; portF.text = String(s.port)
        open()
    }
    function save(connect) {
        if (!hostF.text.trim()) { hostF.error = true; shake.restart(); hostF.focusInput(); return }
        // Credentials come from a saved set (credentialId) or are entered at the
        // connect prompt. Any legacy inline username/password on the connection is
        // preserved when no set is chosen.
        const prev = editId ? ConnectionStore.host(editId) : {}
        const id = ConnectionStore.saveHost({
            id: editId, name: nameF.text, host: hostF.text, port: parseInt(portF.text) || 3389,
            username: credentialId === "" ? (prev.username || "") : "",
            domain: credentialId === "" ? (prev.domain || "") : "",
            share: sharePath, gateway: gatewayF.text, useUdp: udpSwitch.checked,
            credentialId: credentialId, folderId: folderId
        })
        close()
        saved(nameF.text || hostF.text, connect, id)
    }

    onOpened: (editing ? nameF : hostF).focusInput()

    Overlay.modal: Rectangle { color: Theme.overlay }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "x"; from: root.parent.width; to: root.parent.width - root.width; duration: 380; easing.type: Easing.OutQuint }
            NumberAnimation { property: "opacity"; from: 0.4; to: 1; duration: Theme.normal }
        }
    }
    exit: Transition {
        NumberAnimation { property: "x"; to: root.parent.width; duration: 240; easing.type: Easing.InCubic }
    }

    background: Item {
        RectangularShadow {
            anchors.fill: sheet
            blur: 40
            offset.x: -10
            color: Qt.rgba(0, 0, 0, Theme.dark ? 0.55 : 0.18)
        }
        Rectangle {
            id: sheet
            anchors.fill: parent
            color: Theme.surface
            Rectangle { width: 1; height: parent.height; color: Theme.border }
        }
    }

    contentItem: ColumnLayout {
        spacing: 0
        transform: Translate { id: shakeX }
        SequentialAnimation {
            id: shake
            NumberAnimation { target: shakeX; property: "x"; to: -8; duration: 50 }
            NumberAnimation { target: shakeX; property: "x"; to: 6; duration: 60 }
            NumberAnimation { target: shakeX; property: "x"; to: 0; duration: 90; easing.type: Easing.OutBack }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 24
            Layout.bottomMargin: 8
            Column {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: root.editing ? qsTr("Edit connection") : qsTr("New connection")
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Bold
                }
                Text {
                    text: qsTr("Passwords are stored in your system keychain.")
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontSm
                }
            }
            IconButton { iconName: "x"; onClicked: root.close() }
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: form.implicitHeight + 24
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: form
                width: parent.width - 48
                x: 24
                y: 12
                spacing: 18

                Field { id: hostF; Layout.fillWidth: true; label: qsTr("Host"); placeholder: "server.example.com"; mono: true; iconName: "monitor"
                    input.onTextChanged: error = false; onAccepted: root.save(false) }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Field { id: nameF; Layout.fillWidth: true; label: qsTr("Display name"); placeholder: qsTr("Optional"); onAccepted: root.save(false) }
                    Field { id: portF; Layout.preferredWidth: 96; label: qsTr("Port"); placeholder: "3389"; mono: true
                        input.validator: IntValidator { bottom: 1; top: 65535 }
                        onAccepted: root.save(false) }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border; Layout.topMargin: 4 }
                Column {
                    Layout.fillWidth: true
                    spacing: 6
                    Text { text: qsTr("Credentials"); color: Theme.textDim; font.pixelSize: Theme.fontSm; font.weight: Font.Medium }

                    // Pick a saved credential set, or enter one inline.
                    CredentialPicker {
                        width: parent.width
                        credentialId: root.credentialId
                        onChosen: (id) => root.credentialId = id
                        onManage: (addNew) => root.manageCredentials(addNew)
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 5
                    Field {
                        id: gatewayF
                        width: parent.width
                        label: qsTr("RD Gateway")
                        placeholder: qsTr("Optional — gateway.example.com[:443]")
                        mono: true
                        onAccepted: root.save(false)
                    }
                    Text {
                        width: parent.width
                        text: qsTr("Tunnel through this gateway using the same credentials.")
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        wrapMode: Text.WordWrap
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 5
                    Toggle {
                        id: udpSwitch
                        label: qsTr("Use UDP transport")
                    }
                    Text {
                        width: parent.width
                        text: qsTr("Faster on lossy or high-latency links, but opens an extra UDP channel. Off uses TCP only.")
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        wrapMode: Text.WordWrap
                    }
                }


            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 20
            spacing: 10
            IconButton {
                visible: root.editing
                iconName: "trash"
                danger: true
                tip: qsTr("Delete connection")
                onClicked: {
                    const n = nameF.text || hostF.text
                    SessionManager.forgetPassword(root.editId)
                    ConnectionStore.remove(root.editId)
                    root.close()
                    root.deleted(n)
                }
            }
            Item { Layout.fillWidth: true }
            GhostButton { text: qsTr("Save"); onClicked: root.save(false) }
            PrimaryButton { text: qsTr("Save & connect"); iconName: "arrow-right"; onClicked: root.save(true) }
        }
    }
}
