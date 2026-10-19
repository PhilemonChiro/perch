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
    property string connType: "rdp"   // "rdp" | "mssql" | "postgres"
    readonly property bool isSql: connType === "mssql" || connType === "postgres"
    readonly property string defPort: connType === "postgres" ? "5432"
                                    : connType === "mssql" ? "1433" : "3389"
    signal manageCredentials(bool addNew)

    function reset() {
        nameF.text = ""; hostF.text = ""; portF.text = "3389"; gatewayF.text = ""
        udpSwitch.checked = false
        sharePath = ""
        credentialId = ""
        folderId = ""
        connType = "rdp"
        userF.text = ""; dbF.text = ""
        hostF.error = false
    }
    // Switches connection type, moving the port to the new default if it's still
    // the old default.
    // The engine to restore when switching back to a Database connection.
    property string lastEngine: "mssql"
    function setType(t) {
        if (connType === t) return
        // Move the port to the new type's default if it's still the old default.
        if (portF.text === defPort || portF.text === "")
            portF.text = t === "postgres" ? "5432" : t === "mssql" ? "1433" : "3389"
        connType = t
        if (t === "mssql" || t === "postgres") lastEngine = t
    }
    // Top-level kind switch: "rdp" or "db" (which restores the last engine).
    function setKind(k) {
        if (k === "rdp") setType("rdp")
        else if (!isSql) setType(lastEngine)
    }
    function openNew(folder) {
        editId = ""; reset(); folderId = folder || ""; open()
    }
    function openNewDatabase(folder) {
        editId = ""; reset(); setType("mssql"); folderId = folder || ""; open()
    }
    function openEdit(id) {
        const h = ConnectionStore.host(id)
        if (!h.id) return
        editId = id; reset()
        connType = h.type === "mssql" ? "mssql" : h.type === "postgres" ? "postgres" : "rdp"
        nameF.text = h.name === h.host ? "" : h.name
        hostF.text = h.host; portF.text = String(h.port)
        userF.text = h.username || ""
        dbF.text = h.database || ""
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
        const defPort = root.isSql ? 1433 : 3389
        const id = ConnectionStore.saveHost({
            id: editId, name: nameF.text, host: hostF.text, port: parseInt(portF.text) || defPort,
            type: root.connType,
            database: root.isSql ? dbF.text.trim() : "",
            username: root.isSql ? userF.text.trim()
                    : (credentialId === "" ? (prev.username || "") : ""),
            domain: credentialId === "" ? (prev.domain || "") : "",
            share: sharePath, gateway: gatewayF.text, useUdp: udpSwitch.checked,
            credentialId: root.isSql ? "" : credentialId, folderId: folderId
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

                // Connection type — only when creating; an existing connection's
                // type is fixed, so it's hidden while editing.
                Column {
                    Layout.fillWidth: true
                    visible: !root.editing
                    spacing: 6
                    Text { text: qsTr("Type"); color: Theme.textDim; font.pixelSize: Theme.fontSm; font.weight: Font.Medium }
                    // Two kinds — Remote Desktop or Database. The specific
                    // database engine is then chosen from the dropdown below.
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        Repeater {
                            model: [
                                { k: "rdp", label: qsTr("Remote Desktop"), icon: "monitor" },
                                { k: "db", label: qsTr("Database"), icon: "database" }
                            ]
                            delegate: AbstractButton {
                                required property var modelData
                                readonly property bool sel: modelData.k === "rdp" ? root.connType === "rdp" : root.isSql
                                readonly property color col: modelData.k === "rdp" ? Theme.rdpTag : Theme.engineColor(root.connType)
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                implicitHeight: 38
                                hoverEnabled: true
                                focusPolicy: Qt.NoFocus
                                onClicked: root.setKind(modelData.k)
                                background: Rectangle {
                                    radius: Theme.radius
                                    color: sel ? Qt.rgba(col.r, col.g, col.b, 0.12)
                                               : (hovered ? Theme.surface2 : "transparent")
                                    border.color: sel ? col : Theme.border
                                    border.width: sel ? 1.5 : 1
                                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                                }
                                contentItem: RowLayout {
                                    spacing: 8
                                    Icon { Layout.leftMargin: 11; name: modelData.icon; size: 16; color: sel ? col : Theme.textDim }
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.rightMargin: 6
                                        text: modelData.label
                                        color: sel ? Theme.text : Theme.textDim
                                        font.pixelSize: Theme.fontMd
                                        font.weight: sel ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }

                    // Database engine, shown only for a database connection.
                    ComboBox {
                        id: engineBox
                        width: parent.width
                        height: 38
                        visible: root.isSql
                        topInset: 4
                        textRole: "label"
                        readonly property var choices: [
                            { t: "mssql", label: qsTr("SQL Server"), col: Theme.sqlTag },
                            { t: "postgres", label: qsTr("PostgreSQL"), col: Theme.pgTag }
                        ]
                        model: choices
                        currentIndex: root.connType === "postgres" ? 1 : 0
                        onActivated: (i) => root.setType(choices[i].t)
                        // Keep the shown engine correct when the kind buttons
                        // restore the last engine (user selection breaks the binding).
                        Connections {
                            target: root
                            function onConnTypeChanged() {
                                if (root.isSql) engineBox.currentIndex = root.connType === "postgres" ? 1 : 0
                            }
                        }

                        contentItem: RowLayout {
                            spacing: 9
                            Icon { Layout.leftMargin: 12; name: "database"; size: 15
                                color: Theme.engineColor(root.connType) }
                            Text {
                                Layout.fillWidth: true
                                text: engineBox.choices[engineBox.currentIndex].label
                                color: Theme.text; font.pixelSize: Theme.fontMd; elide: Text.ElideRight
                            }
                        }
                        indicator: Icon {
                            x: engineBox.width - width - 12; y: (engineBox.height - height) / 2
                            name: "chevron"; size: 12; color: Theme.textFaint
                            rotation: engineBox.popup.visible ? -90 : 90
                            Behavior on rotation { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
                        }
                        background: Rectangle {
                            radius: Theme.radius; color: Theme.surface2
                            border.color: engineBox.popup.visible || engineBox.activeFocus ? Theme.accent
                                        : engineBox.hovered ? Theme.borderStrong : Theme.border
                            Behavior on border.color { ColorAnimation { duration: Theme.fast } }
                        }
                        delegate: ItemDelegate {
                            id: ed
                            required property var modelData
                            required property int index
                            width: engineBox.width - 12; x: 6; height: 34
                            highlighted: engineBox.highlightedIndex === index
                            contentItem: RowLayout {
                                spacing: 9
                                Icon { Layout.leftMargin: 8; name: "database"; size: 14; color: ed.modelData.col }
                                Text { Layout.fillWidth: true; text: ed.modelData.label; color: Theme.text
                                    font.pixelSize: Theme.fontMd; elide: Text.ElideRight }
                                Rectangle { visible: engineBox.currentIndex === ed.index; Layout.rightMargin: 10
                                    width: 6; height: 6; radius: 3; color: Theme.accent }
                            }
                            background: Rectangle { radius: Theme.radiusSm
                                color: ed.highlighted ? Theme.hover : "transparent"; anchors.fill: parent }
                        }
                        popup: Popup {
                            y: engineBox.height + 4; width: engineBox.width
                            implicitHeight: contentItem.implicitHeight + 12; padding: 6
                            enter: Transition { ParallelAnimation {
                                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
                                NumberAnimation { property: "y"; from: engineBox.height - 2; to: engineBox.height + 4; duration: Theme.normal; easing.type: Theme.easing } } }
                            contentItem: ListView {
                                clip: true; implicitHeight: contentHeight; spacing: 2
                                model: engineBox.popup.visible ? engineBox.delegateModel : null
                                currentIndex: engineBox.highlightedIndex
                            }
                            background: Rectangle {
                                radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong
                                RectangularShadow { anchors.fill: parent; radius: parent.radius; blur: 24; offset.y: 6; spread: 0; color: Qt.rgba(0, 0, 0, Theme.dark ? 0.45 : 0.14); z: -1 }
                            }
                        }
                    }
                }

                Field { id: hostF; Layout.fillWidth: true; label: qsTr("Host"); placeholder: "server.example.com"; mono: true
                    iconName: root.isSql ? "database" : "monitor"
                    input.onTextChanged: error = false; onAccepted: root.save(false) }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Field { id: nameF; Layout.fillWidth: true; label: qsTr("Display name"); placeholder: qsTr("Optional"); onAccepted: root.save(false) }
                    Field { id: portF; Layout.preferredWidth: 96; label: qsTr("Port"); placeholder: root.defPort; mono: true
                        input.validator: IntValidator { bottom: 1; top: 65535 }
                        onAccepted: root.save(false) }
                }

                // SQL-only: login user and default database.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    visible: root.isSql
                    Field { id: userF; Layout.fillWidth: true; label: qsTr("Username"); placeholder: qsTr("e.g. sa"); mono: true; onAccepted: root.save(false) }
                    Field { id: dbF; Layout.fillWidth: true; label: qsTr("Database"); placeholder: qsTr("Optional — pick after connect"); mono: true; onAccepted: root.save(false) }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border; Layout.topMargin: 4; visible: !root.isSql }
                Column {
                    Layout.fillWidth: true
                    spacing: 6
                    visible: !root.isSql
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
                    visible: !root.isSql
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
                    visible: !root.isSql
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

                // SQL note: the password is entered when you connect, not stored here.
                Text {
                    Layout.fillWidth: true
                    visible: root.isSql
                    text: qsTr("You'll enter the password when you connect. It's kept only in memory for that session.")
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontXs
                    wrapMode: Text.WordWrap
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
