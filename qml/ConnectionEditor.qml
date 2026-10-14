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

    Connections { target: CredentialStore; function onChanged() { root.refreshCreds() } }

    signal saved(string name, bool connect, string id)
    signal deleted(string name)

    property string editId: ""
    property string folderId: ""
    readonly property bool editing: editId !== ""
    property string sharePath: ""
    property string credentialId: ""
    property var credChoices: []
    signal manageCredentials(bool addNew)

    function refreshCreds() {
        const saved = CredentialStore.list().map(c => ({ id: c.id, label: c.label, sub: (c.domain ? c.domain + "\\" : "") + c.username }))
        credChoices = [{ id: "", label: qsTr("Ask when connecting"), sub: "" }]
            .concat(saved)
            .concat([{ id: "__new__", label: qsTr("New credential…"), sub: "" },
                     { id: "__manage__", label: qsTr("Manage credentials…"), sub: "" }])
        syncCred()
    }
    function credIndex(id) {
        for (let i = 0; i < credChoices.length; ++i) if (credChoices[i].id === id) return i
        return 0
    }
    function syncCred() { credBox.currentIndex = credIndex(credentialId) }

    function reset() {
        nameF.text = ""; hostF.text = ""; portF.text = "3389"; gatewayF.text = ""
        sharePath = ""
        credentialId = ""
        folderId = ""
        hostF.error = false
        refreshCreds()
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
        sharePath = h.share || ""
        credentialId = h.credentialId || ""
        folderId = h.folderId || ""
        syncCred()
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
            share: sharePath, gateway: gatewayF.text, credentialId: credentialId,
            folderId: folderId
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
                    ComboBox {
                    id: credBox
                    width: parent.width
                    height: 38
                    model: root.credChoices
                    textRole: "label"
                    readonly property bool hasCred: root.credentialId !== ""
                    readonly property var sel: root.credChoices[currentIndex] || root.credChoices[0]
                    onActivated: (i) => {
                        const v = root.credChoices[i] ? root.credChoices[i].id : ""
                        if (v === "__manage__") { root.syncCred(); root.manageCredentials(false) }
                        else if (v === "__new__") { root.syncCred(); root.manageCredentials(true) }
                        else root.credentialId = v
                    }
                    delegate: ItemDelegate {
                        id: cd
                        required property var modelData
                        required property int index
                        readonly property bool actionRow: cd.modelData.id === "__manage__" || cd.modelData.id === "__new__"
                        width: credBox.width - 12; x: 6; height: 34
                        highlighted: credBox.highlightedIndex === index
                        contentItem: RowLayout {
                            spacing: 9
                            Icon {
                                Layout.leftMargin: 8
                                name: cd.modelData.id === "__new__" ? "plus" : cd.modelData.id === "__manage__" ? "pencil" : "lock"
                                size: 14
                                color: cd.actionRow ? Theme.accent : Theme.textDim
                            }
                            Text { text: cd.modelData.label; color: cd.actionRow ? Theme.accent : Theme.text; font.pixelSize: Theme.fontMd; elide: Text.ElideRight }
                            Text { visible: cd.modelData.sub !== "" && cd.modelData.sub !== cd.modelData.label; Layout.fillWidth: true; text: cd.modelData.sub; color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight; rightPadding: 6 }
                            Item { visible: cd.modelData.sub === "" || cd.modelData.sub === cd.modelData.label; Layout.fillWidth: true }
                        }
                        background: Rectangle { radius: Theme.radiusSm; color: cd.highlighted ? Theme.surface3 : "transparent" }
                    }
                    contentItem: Text {
                        leftPadding: 36; rightPadding: 34
                        verticalAlignment: Text.AlignVCenter
                        text: {
                            if (!credBox.sel) return ""
                            const l = credBox.sel.label, s = credBox.sel.sub
                            return (credBox.hasCred && s && s !== l) ? l + "   " + s : l
                        }
                        color: credBox.hasCred ? Theme.text : Theme.textDim
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }
                    Icon {
                        name: "lock"; size: 15
                        color: credBox.hasCred ? Theme.accent : Theme.textFaint
                        anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                    }
                    indicator: Icon {
                        x: credBox.width - width - 12; y: (credBox.height - height) / 2
                        name: "chevron"; size: 12; color: Theme.textFaint
                        rotation: credBox.popup.visible ? -90 : 90
                        Behavior on rotation { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
                    }
                    background: Rectangle {
                        radius: Theme.radius; color: Theme.surface2
                        border.color: credBox.popup.visible || credBox.activeFocus ? Theme.accent : credBox.hovered ? Theme.borderStrong : Theme.border
                        Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                    }
                    popup: Popup {
                        y: credBox.height + 4; width: credBox.width
                        implicitHeight: Math.min(contentItem.implicitHeight + 12, 340); padding: 6
                        enter: Transition { ParallelAnimation {
                            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                            NumberAnimation { property: "y"; from: credBox.height - 2; to: credBox.height + 4; duration: Theme.normal; easing.type: Theme.easing } } }
                        contentItem: ListView {
                            clip: true; implicitHeight: contentHeight; spacing: 2
                            model: credBox.popup.visible ? credBox.delegateModel : null
                            currentIndex: credBox.highlightedIndex
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        }
                        background: Rectangle {
                            radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong
                            RectangularShadow { anchors.fill: parent; radius: parent.radius; blur: 24; offset.y: 6; spread: 0; color: Qt.rgba(0, 0, 0, Theme.dark ? 0.45 : 0.14); z: -1 }
                        }
                    }
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
