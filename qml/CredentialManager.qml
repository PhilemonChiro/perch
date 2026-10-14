import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import Relay

// Slide-over sheet to manage reusable credential sets. Two states: a list of
// saved credentials, and a form to add or edit one.
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

    // "" = list view; "new" or an id = form view.
    property string editingId: ""
    readonly property bool formView: editingId !== ""
    property var creds: []
    // One-shot callback(id) invoked after a *new* credential is saved, when the
    // manager was opened to add one on another view's behalf (e.g. the "New
    // credential…" row of a connection's picker). It lets the caller select the
    // freshly created set and we close back to it, instead of dropping the user
    // on the list to pick it again.
    property var pickHandler: null

    function refresh() { creds = CredentialStore.list() }
    function openManager() { pickHandler = null; editingId = ""; refresh(); open() }

    function startAdd() {
        editingId = "new"
        labelF.text = ""; userF.text = ""; passF.text = ""
        labelF.focusInput()
    }
    // Add a credential and hand its id back to `handler` on save.
    function startAddInto(handler) { pickHandler = handler; startAdd() }
    function cancelForm() { pickHandler = null; editingId = "" }
    function startEdit(id) {
        const c = CredentialStore.get(id)
        if (!c.id) return
        editingId = id
        labelF.text = c.label
        userF.text = c.domain ? (c.domain + "\\" + c.username) : c.username
        passF.text = ""
    }
    function saveForm() {
        if (!userF.text.trim()) { userF.error = true; userF.focusInput(); return }
        const wasNew = editingId === "new"
        const id = CredentialStore.save({
            id: editingId === "new" ? "" : editingId,
            label: labelF.text, username: userF.text, domain: "", password: passF.text
        })
        refresh()
        if (wasNew && pickHandler) {
            const h = pickHandler; pickHandler = null
            h(id)
            close()
        } else {
            editingId = ""
        }
    }

    Overlay.modal: Rectangle { color: Theme.overlay; Behavior on opacity { NumberAnimation { duration: Theme.normal } } }
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
        NumberAnimation { property: "x"; from: root.parent.width; to: root.parent.width - root.width; duration: Theme.slow; easing.type: Theme.easingEmph } } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }

    background: Rectangle {
        color: Theme.surface
        border.color: Theme.border
        RectangularShadow { anchors.fill: parent; blur: 48; offset.x: -12; spread: 0; color: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.16); z: -1 }
    }

    contentItem: ColumnLayout {
        spacing: 0

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 24
            Layout.bottomMargin: 8
            spacing: 10
            IconButton {
                visible: root.formView
                iconName: "chevron"; iconSize: 15
                rotation: 180
                tip: qsTr("Back")
                onClicked: root.cancelForm()
            }
            Column {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: !root.formView ? qsTr("Credentials")
                        : root.editingId === "new" ? qsTr("New credential") : qsTr("Edit credential")
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                }
                Text {
                    text: qsTr("Reusable sign-ins. Passwords are stored in your system keychain.")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
            }
            IconButton { iconName: "x"; iconSize: 16; onClicked: root.close() }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ---- List view ----
        ColumnLayout {
            visible: !root.formView
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 12
                clip: true
                model: root.creds
                spacing: 4
                boundsBehavior: Flickable.StopAtBounds

                delegate: AbstractButton {
                    id: row
                    required property var modelData
                    width: list.width
                    implicitHeight: 54
                    hoverEnabled: true
                    focusPolicy: Qt.NoFocus
                    onClicked: root.startEdit(modelData.id)
                    background: Rectangle {
                        radius: Theme.radius
                        color: row.hovered ? Theme.surface2 : "transparent"
                        border.color: row.hovered ? Theme.border : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                    }
                    contentItem: RowLayout {
                        spacing: 10
                        Rectangle {
                            Layout.leftMargin: 10
                            width: 34; height: 34; radius: 10
                            color: Theme.accentSoft
                            Icon { anchors.centerIn: parent; name: "lock"; size: 15; color: Theme.accent }
                        }
                        Column {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: row.modelData.label; color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.Medium; elide: Text.ElideRight; width: parent.width }
                            Text {
                                text: (row.modelData.domain ? row.modelData.domain + "\\" : "") + row.modelData.username
                                color: Theme.textDim; font.pixelSize: Theme.fontSm; font.family: Theme.monoFamily
                                elide: Text.ElideRight; width: parent.width
                            }
                        }
                        IconButton {
                            iconName: "trash"; iconSize: 14; danger: true
                            Layout.rightMargin: 8
                            opacity: row.hovered ? 1 : 0
                            tip: qsTr("Delete")
                            onClicked: { CredentialStore.remove(row.modelData.id); root.refresh() }
                        }
                    }
                }

                // Empty state
                Column {
                    anchors.centerIn: parent
                    width: parent.width - 48
                    spacing: 10
                    visible: list.count === 0
                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: qsTr("No saved credentials yet"); color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold }
                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: qsTr("Save a sign-in once and reuse it across connections."); color: Theme.textDim; font.pixelSize: Theme.fontSm }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 20
                Item { Layout.fillWidth: true }
                PrimaryButton { text: qsTr("Add credential"); iconName: "plus"; onClicked: root.startAdd() }
            }
        }

        // ---- Form view ----
        ColumnLayout {
            visible: root.formView
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 24
            Layout.topMargin: 18
            spacing: 16

            Field { id: labelF; Layout.fillWidth: true; label: qsTr("Label"); placeholder: qsTr("e.g. Domain admin"); onAccepted: userF.focusInput() }
            Field { id: userF; Layout.fillWidth: true; label: qsTr("Username"); placeholder: qsTr("administrator  or  DOMAIN\\user"); input.onTextChanged: error = false; onAccepted: passF.focusInput() }
            Field { id: passF; Layout.fillWidth: true; label: qsTr("Password"); password: true
                placeholder: root.editingId === "new" ? qsTr("Optional — you’ll be asked when connecting") : qsTr("Leave blank to keep the saved one")
                onAccepted: root.saveForm() }

            Item { Layout.fillHeight: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                GhostButton { text: qsTr("Cancel"); onClicked: root.cancelForm() }
                Item { Layout.fillWidth: true }
                PrimaryButton { text: qsTr("Save"); iconName: "enter"; onClicked: root.saveForm() }
            }
        }
    }
}
