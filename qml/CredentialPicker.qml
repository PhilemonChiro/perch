import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import Relay

// Reusable credential selector: lists saved credential sets, plus "New
// credential…" and "Manage credentials…". Matches the Field input style.
ComboBox {
    id: box
    height: 38
    textRole: "label"

    // The currently selected set id ("" = none / ask when connecting).
    property string credentialId: ""
    // Emitted when a real set (or "") is chosen.
    signal chosen(string id)
    // Emitted for the action rows; addNew true for "New credential…".
    signal manage(bool addNew)

    property var choices: []
    readonly property bool hasCred: credentialId !== ""
    readonly property var sel: choices[currentIndex] || choices[0]

    function refresh() {
        const saved = CredentialStore.list().map(c => ({ id: c.id, label: c.label,
            sub: (c.domain ? c.domain + "\\" : "") + c.username }))
        choices = [{ id: "", label: qsTr("Ask when connecting"), sub: "" }]
            .concat(saved)
            .concat([{ id: "__new__", label: qsTr("New credential…"), sub: "" },
                     { id: "__manage__", label: qsTr("Manage credentials…"), sub: "" }])
        syncIndex()
    }
    function idxOf(id) { for (let i = 0; i < choices.length; ++i) if (choices[i].id === id) return i; return 0 }
    function syncIndex() { currentIndex = idxOf(credentialId) }
    onCredentialIdChanged: syncIndex()
    model: choices
    Component.onCompleted: refresh()
    Connections { target: CredentialStore; function onChanged() { box.refresh() } }

    onActivated: (i) => {
        const v = choices[i] ? choices[i].id : ""
        if (v === "__manage__") { syncIndex(); box.manage(false) }
        else if (v === "__new__") { syncIndex(); box.manage(true) }
        else box.chosen(v) // parent owns credentialId; it flows back via binding
    }

    delegate: ItemDelegate {
        id: cd
        required property var modelData
        required property int index
        readonly property bool actionRow: cd.modelData.id === "__manage__" || cd.modelData.id === "__new__"
        // "New credential…" is the first action row: rule it off from the saved sets.
        readonly property bool firstAction: cd.modelData.id === "__new__"
        width: box.width - 12; x: 6; height: cd.firstAction ? 43 : 34
        topPadding: cd.firstAction ? 9 : 0
        highlighted: box.highlightedIndex === index
        // Separator between saved credentials and the action rows.
        Rectangle {
            visible: cd.firstAction
            anchors { top: parent.top; left: parent.left; right: parent.right; leftMargin: 4; rightMargin: 4 }
            height: 1
            color: Theme.border
        }
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
        background: Rectangle {
            radius: Theme.radiusSm
            color: cd.highlighted ? Theme.surface3 : "transparent"
            anchors.fill: parent
            anchors.topMargin: cd.firstAction ? 9 : 0
        }
    }

    contentItem: Text {
        leftPadding: 36; rightPadding: 34
        verticalAlignment: Text.AlignVCenter
        text: {
            if (!box.sel) return ""
            const l = box.sel.label, s = box.sel.sub
            return (box.hasCred && s && s !== l) ? l + "   " + s : l
        }
        color: box.hasCred ? Theme.text : Theme.textDim
        font.pixelSize: Theme.fontMd
        elide: Text.ElideRight
    }
    Icon {
        name: "lock"; size: 15
        color: box.hasCred ? Theme.accent : Theme.textFaint
        anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    indicator: Icon {
        x: box.width - width - 12; y: (box.height - height) / 2
        name: "chevron"; size: 12; color: Theme.textFaint
        rotation: box.popup.visible ? -90 : 90
        Behavior on rotation { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack } }
    }
    background: Rectangle {
        radius: Theme.radius; color: Theme.surface2
        border.color: box.popup.visible || box.activeFocus ? Theme.accent : box.hovered ? Theme.borderStrong : Theme.border
        Behavior on border.color { ColorAnimation { duration: Theme.fast } }
    }
    popup: Popup {
        y: box.height + 4; width: box.width
        implicitHeight: Math.min(contentItem.implicitHeight + 12, 340); padding: 6
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
            NumberAnimation { property: "y"; from: box.height - 2; to: box.height + 4; duration: Theme.normal; easing.type: Theme.easing } } }
        contentItem: ListView {
            clip: true; implicitHeight: contentHeight; spacing: 2
            model: box.popup.visible ? box.delegateModel : null
            currentIndex: box.highlightedIndex
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        }
        background: Rectangle {
            radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong
            RectangularShadow { anchors.fill: parent; radius: parent.radius; blur: 24; offset.y: 6; spread: 0; color: Qt.rgba(0, 0, 0, Theme.dark ? 0.45 : 0.14); z: -1 }
        }
    }
}
