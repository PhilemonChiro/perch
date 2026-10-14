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
    property var folderChoices: []
    property string sharePath: ""
    property string credentialId: ""
    property var credChoices: []
    signal manageCredentials(bool addNew)

    function refreshCreds() {
        const saved = CredentialStore.list().map(c => ({ id: c.id, label: c.label, sub: (c.domain ? c.domain + "\\" : "") + c.username }))
        credChoices = [{ id: "", label: qsTr("Enter manually"), sub: "" }]
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
        nameF.text = ""; hostF.text = ""; portF.text = "3389"; userF.text = ""; passF.text = ""; gatewayF.text = ""
        sharePath = ""
        credentialId = ""
        hostF.error = false
        folderChoices = [{ id: "", name: qsTr("No folder"), depth: 0 }].concat(ConnectionStore.folders())
        refreshCreds()
    }
    function selectFolder(id) {
        for (let i = 0; i < folderChoices.length; ++i)
            if (folderChoices[i].id === id) { folderBox.currentIndex = i; return }
        folderBox.currentIndex = 0
    }
    function openNew(folder) {
        editId = ""; reset(); selectFolder(folder || ""); open()
    }
    function openEdit(id) {
        const h = ConnectionStore.host(id)
        if (!h.id) return
        editId = id; reset()
        nameF.text = h.name === h.host ? "" : h.name
        hostF.text = h.host; portF.text = String(h.port)
        userF.text = h.domain ? (h.domain + "\\" + h.username) : h.username
        gatewayF.text = h.gateway || ""
        sharePath = h.share || ""
        credentialId = h.credentialId || ""
        syncCred()
        selectFolder(h.folderId)
        open()
    }
    function openFromSession(s) {
        editId = ""; reset(); selectFolder("")
        hostF.text = s.host; portF.text = String(s.port)
        userF.text = s.domain ? (s.domain + "\\" + s.username) : s.username
        open()
    }
    function save(connect) {
        if (!hostF.text.trim()) { hostF.error = true; shake.restart(); hostF.focusInput(); return }
        const id = ConnectionStore.saveHost({
            id: editId, name: nameF.text, host: hostF.text, port: parseInt(portF.text) || 3389,
            username: credentialId === "" ? userF.text : "", domain: "",
            share: sharePath, gateway: gatewayF.text, credentialId: credentialId,
            folderId: folderChoices[folderBox.currentIndex] ? folderChoices[folderBox.currentIndex].id : ""
        })
        const pass = passF.text
        if (pass) SessionManager.storePassword(id, pass)
        close()
        if (connect && pass) {
            // Connect with the password we just captured; the keychain write above
            // is async and a plain openHost() would race it and fall back to a prompt.
            SessionManager.openHostWithPassword(id, pass)
            saved(nameF.text || hostF.text, false, id)
        } else {
            saved(nameF.text || hostF.text, connect, id)
        }
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
                Text { text: qsTr("CREDENTIALS"); color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.weight: Font.DemiBold; font.letterSpacing: 0.8 }

                // Pick a saved credential set, or enter one inline.
                ComboBox {
                    id: credBox
                    Layout.fillWidth: true
                    height: 46
                    model: root.credChoices
                    textRole: "label"
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
                        width: credBox.width - 12; x: 6
                        height: actionRow || !cd.modelData.sub ? 34 : 44
                        highlighted: credBox.highlightedIndex === index
                        contentItem: RowLayout {
                            spacing: 10
                            Icon {
                                Layout.leftMargin: 6
                                name: cd.modelData.id === "__new__" ? "plus" : cd.modelData.id === "__manage__" ? "pencil" : "lock"
                                size: 14
                                color: cd.actionRow ? Theme.accent : Theme.textDim
                            }
                            Column {
                                Layout.fillWidth: true
                                spacing: 1
                                Text { text: cd.modelData.label; color: cd.actionRow ? Theme.accent : Theme.text; font.pixelSize: Theme.fontMd; elide: Text.ElideRight; width: parent.width }
                                Text { visible: cd.modelData.sub !== ""; text: cd.modelData.sub; color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily; elide: Text.ElideRight; width: parent.width }
                            }
                        }
                        background: Rectangle { radius: Theme.radiusSm; color: cd.highlighted ? Theme.surface3 : "transparent" }
                    }
                    contentItem: RowLayout {
                        spacing: 10
                        Icon { Layout.leftMargin: 12; name: "lock"; size: 15; color: root.credentialId === "" ? Theme.textDim : Theme.accent }
                        Column {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: credBox.sel ? credBox.sel.label : ""; color: Theme.text; font.pixelSize: Theme.fontMd; elide: Text.ElideRight; width: parent.width }
                            Text { visible: !!(credBox.sel && credBox.sel.sub); text: credBox.sel && credBox.sel.sub ? credBox.sel.sub : ""; color: Theme.textFaint; font.pixelSize: Theme.fontXs; font.family: Theme.monoFamily; elide: Text.ElideRight; width: parent.width }
                        }
                        Item { Layout.preferredWidth: 20 }
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
                        implicitHeight: Math.min(contentItem.implicitHeight + 12, 320); padding: 6
                        contentItem: ListView { clip: true; implicitHeight: contentHeight; model: credBox.popup.visible ? credBox.delegateModel : null; currentIndex: credBox.highlightedIndex }
                        background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                    }
                }

                Field { id: userF; visible: root.credentialId === ""; Layout.fillWidth: true; label: qsTr("Username"); placeholder: qsTr("administrator  or  DOMAIN\\user"); onAccepted: root.save(false) }
                Field {
                    id: passF
                    visible: root.credentialId === ""
                    Layout.fillWidth: true
                    label: qsTr("Password")
                    password: true
                    placeholder: root.editing ? qsTr("Leave blank to keep the saved one") : qsTr("Optional — you’ll be asked when connecting")
                    onAccepted: root.save(false)
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

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border; Layout.topMargin: 4 }

                Column {
                    Layout.fillWidth: true
                    spacing: 6
                    Text { text: qsTr("Folder"); color: Theme.textDim; font.pixelSize: Theme.fontSm; font.weight: Font.Medium }
                    ComboBox {
                        id: folderBox
                        width: parent.width
                        height: 38
                        model: root.folderChoices
                        textRole: "name"
                        delegate: ItemDelegate {
                            id: fd
                            required property var modelData
                            required property int index
                            width: folderBox.width - 12
                            x: 6
                            height: 32
                            highlighted: folderBox.highlightedIndex === index
                            contentItem: Text {
                                leftPadding: 4 + fd.modelData.depth * 14
                                text: fd.modelData.name
                                color: Theme.text
                                font.pixelSize: Theme.fontMd
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle { radius: Theme.radiusSm; color: fd.highlighted ? Theme.surface3 : "transparent" }
                        }
                        contentItem: Text {
                            leftPadding: 12
                            text: folderBox.displayText
                            color: Theme.text
                            font.pixelSize: Theme.fontMd
                            verticalAlignment: Text.AlignVCenter
                        }
                        indicator: Icon {
                            x: folderBox.width - width - 12
                            y: (folderBox.height - height) / 2
                            name: "chevron"; size: 12; color: Theme.textFaint
                            rotation: folderBox.popup.visible ? -90 : 90
                            Behavior on rotation { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
                        }
                        background: Rectangle {
                            radius: Theme.radius
                            color: Theme.surface2
                            border.color: folderBox.popup.visible || folderBox.activeFocus ? Theme.accent : folderBox.hovered ? Theme.borderStrong : Theme.border
                            Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                        }
                        popup: Popup {
                            y: folderBox.height + 4
                            width: folderBox.width
                            implicitHeight: Math.min(contentItem.implicitHeight + 12, 260)
                            padding: 6
                            enter: Transition { ParallelAnimation {
                                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                                NumberAnimation { property: "y"; from: folderBox.height - 4; to: folderBox.height + 4; duration: Theme.normal; easing.type: Theme.easing } } }
                            contentItem: ListView {
                                clip: true
                                implicitHeight: contentHeight
                                model: folderBox.popup.visible ? folderBox.delegateModel : null
                                currentIndex: folderBox.highlightedIndex
                            }
                            background: Rectangle { radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
                        }
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
