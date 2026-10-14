import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Effects
import QtQuick.Layouts
import Relay

Item {
    id: page
    clip: true
    property var sessionObj
    property bool active: false
    property bool fullscreen: false  // windowed controls live in the tab strip
    signal closeRequested()
    signal fullscreenRequested()
    signal saveRequested()
    signal toast(string message, string kind)

    function folderName(path) {
        if (!path) return ""
        const p = path.replace(/[\/\\]+$/, "")
        const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
        return i >= 0 ? p.substring(i + 1) : p
    }
    // Mount (or change) the shared folder on the live session, persist it, reconnect.
    function applyShare(path) {
        if (!sessionObj) return
        sessionObj.shareFolder(path)
        if (sessionObj.hostId !== "")
            ConnectionStore.setShare(sessionObj.hostId, path)
        page.toast(path ? qsTr("Mounting “%1”…").arg(folderName(path))
                        : qsTr("Unmounting shared folder…"), "info")
    }

    readonly property int st: sessionObj ? sessionObj.state : 0
    readonly property bool live: st === RdpSession.Connected && sessionObj.hasFrame
    // A quick in-place reconnect to apply a shared folder — kept non-disruptive.
    readonly property bool remounting: sessionObj ? sessionObj.remounting : false
    readonly property bool certPending: sessionObj && sessionObj.certificate.fingerprint !== undefined

    onLiveChanged: {
        if (live && active) view.forceActiveFocus()
        if (live && fullscreen) { hotZone.introReveal = true; introTimer.restart() }
    }
    onActiveChanged: if (active && live) view.forceActiveFocus()
    onFullscreenChanged: if (fullscreen && live) { hotZone.introReveal = true; introTimer.restart() }

    // Backdrop shown until the first frame arrives.
    Rectangle {
        anchors.fill: parent
        color: Theme.bg
    }

    RdpView {
        id: view
        anchors.fill: parent
        session: page.sessionObj
        // Desaturate + dim the stale frame when the session isn't live — but keep
        // it crisp during a remount, which is a quick in-place reconnect.
        layer.enabled: !page.live && !page.remounting && visible
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 0.6
            blurMax: 40
            saturation: -0.6
            brightness: Theme.dark ? -0.25 : 0.1
        }
    }

    // Fullscreen-only floating toolbar: the tab strip is hidden there, so a thin
    // bar slides down from the top edge on hover (and briefly on connect).
    Rectangle {
        id: hotZone
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(toolbar.width + 80, 360)
        height: toolbarShown ? toolbar.height + 24 : 12
        color: "transparent"
        visible: page.live && page.fullscreen
        property bool introReveal: false
        property bool toolbarShown: zoneHover.hovered || toolbarHover.hovered || introReveal
        HoverHandler { id: zoneHover }
    }

    // Brief auto-reveal when entering a live fullscreen session.
    Timer { id: introTimer; interval: 2800; onTriggered: hotZone.introReveal = false }

    // Elevation under the toolbar, following its slide.
    RectangularShadow {
        anchors.fill: toolbar
        radius: toolbar.radius
        visible: toolbar.visible
        blur: 30; offset.y: 8; spread: 0
        color: Qt.rgba(0, 0, 0, Theme.dark ? 0.55 : 0.18)
    }
    Rectangle {
        id: toolbar
        anchors.horizontalCenter: parent.horizontalCenter
        visible: (page.live && page.fullscreen) || y > -height
        y: hotZone.toolbarShown && page.live && page.fullscreen ? 10 : -height - 12
        Behavior on y { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutQuint } }
        width: tbRow.implicitWidth + 16
        height: 40
        radius: 20
        color: Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, Theme.dark ? 0.99 : 0.98)
        border.color: Theme.borderStrong
        HoverHandler { id: toolbarHover }
        RowLayout {
            id: tbRow
            anchors.centerIn: parent
            spacing: 4
            StatusDot { Layout.leftMargin: 8; state: page.st }
            Text {
                Layout.leftMargin: 4
                text: page.sessionObj ? page.sessionObj.title : ""
                color: Theme.text
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
            }
            Text {
                Layout.rightMargin: 6
                text: page.sessionObj ? page.sessionObj.remoteSize.width + " × " + page.sessionObj.remoteSize.height : ""
                color: Theme.textFaint
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontXs
            }
            Rectangle { width: 1; height: 16; color: Theme.border }
            IconButton { iconName: "expand"; iconSize: 14; tip: qsTr("Full screen  %1↵").arg(Theme.modLabel); onClicked: page.fullscreenRequested() }
            IconButton {
                id: mountBtn
                iconName: "folder"; iconSize: 14
                readonly property string shared: page.sessionObj ? page.sessionObj.sharedFolder : ""
                checked: shared !== ""
                tip: shared !== "" ? qsTr("Sharing “%1” — click to change").arg(page.folderName(shared))
                                   : qsTr("Share a folder into this session")
                onClicked: shared !== "" ? mountMenu.popup() : folderDialog.open()
                // Accent dot marking an active mount.
                Rectangle {
                    visible: mountBtn.checked
                    width: 6; height: 6; radius: 3
                    color: Theme.accent
                    anchors { right: parent.right; top: parent.top; rightMargin: 4; topMargin: 4 }
                    SequentialAnimation on opacity {
                        running: mountBtn.checked; loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 1100; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
                    }
                }
            }
            IconButton {
                visible: page.sessionObj && page.sessionObj.hostId === ""
                iconName: "plus"; iconSize: 14; tip: qsTr("Save connection")
                onClicked: page.saveRequested()
            }
            IconButton { iconName: "power"; iconSize: 14; danger: true; tip: qsTr("Disconnect"); onClicked: page.sessionObj.disconnect() }
        }
    }

    FolderDialog {
        id: folderDialog
        title: qsTr("Share a folder into this session")
        onAccepted: page.applyShare(ConnectionStore.toLocalPath(selectedFolder))
    }

    Menu {
        id: mountMenu
        padding: 6
        background: Rectangle { implicitWidth: 220; radius: Theme.radius; color: Theme.surface2; border.color: Theme.borderStrong }
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast }
            NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 80 } }
        delegate: MenuItem {
            id: mmi
            implicitHeight: 30
            readonly property bool danger: text === qsTr("Unmount folder")
            contentItem: Text {
                leftPadding: 4; text: mmi.text
                color: mmi.danger ? Theme.danger : Theme.text
                font.pixelSize: Theme.fontMd; verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle { radius: Theme.radiusSm; color: mmi.highlighted ? (mmi.danger ? Theme.dangerSoft : Theme.surface3) : "transparent" }
        }
        Action { text: qsTr("Change folder…"); onTriggered: folderDialog.open() }
        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: Theme.border } }
        Action { text: qsTr("Unmount folder"); onTriggered: page.applyShare("") }
    }

    // Compact, non-disruptive indicator while remounting (quick in-place reconnect).
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 16
        visible: page.remounting
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
        width: remountRow.implicitWidth + 28
        height: 38
        radius: 19
        color: Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.97)
        border.color: Theme.borderStrong
        z: 20
        RectangularShadow {
            anchors.fill: parent; radius: parent.radius
            blur: 28; offset.y: 6; spread: 0
            color: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.16)
            z: -1
        }
        Row {
            id: remountRow
            anchors.centerIn: parent
            spacing: 10
            Spinner { anchors.verticalCenter: parent.verticalCenter; size: 15; thickness: 2 }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Remounting shared folder…")
                color: Theme.text
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
            }
        }
    }

    // Overlay layer for every non-live state (except a remount, handled above).
    Item {
        anchors.fill: parent
        visible: !page.live && !page.remounting

        Loader {
            id: overlay
            anchors.centerIn: parent
            readonly property string kind: page.certPending ? "cert"
                : page.st === RdpSession.NeedsCredentials ? "signin"
                : (page.st === RdpSession.Connecting || page.st === RdpSession.VerifyingCertificate
                   || (page.st === RdpSession.Connected && !page.sessionObj.hasFrame)) ? "progress"
                : (page.st === RdpSession.Disconnected || page.st === RdpSession.Failed) ? "ended"
                : "progress"
            sourceComponent: kind === "cert" ? certComp : kind === "signin" ? signInComp
                           : kind === "ended" ? endedComp : progressComp

            // Cross-fade + rise between overlay kinds.
            onKindChanged: swap.restart()
            SequentialAnimation {
                id: swap
                ParallelAnimation {
                    NumberAnimation { target: overlay; property: "opacity"; from: 0; to: 1; duration: Theme.normal }
                    NumberAnimation { target: overlay; property: "anchors.verticalCenterOffset"; from: 12; to: 0; duration: Theme.slow; easing.type: Theme.easing }
                }
            }
        }
    }

    // ---- Progress ----
    Component {
        id: progressComp
        Column {
            width: 440
            spacing: 0
            readonly property int stage: page.sessionObj ? page.sessionObj.stage : 0
            readonly property real progress: Math.min(1, (stage + 0.5) / 4)
            readonly property var steps: [qsTr("Connect"), qsTr("Secure"), qsTr("Sign in"), qsTr("Desktop")]

            // The host being reached is the hero of this moment.
            Text {
                width: parent.width
                text: page.sessionObj ? page.sessionObj.title : ""
                color: Theme.text
                font.pixelSize: Theme.fontHero
                font.weight: Font.DemiBold
                font.letterSpacing: -0.5
                elide: Text.ElideRight
            }
            Item { width: 1; height: 8 }
            Text {
                text: page.sessionObj ? (page.sessionObj.host + "  ·  " + page.sessionObj.port) : ""
                color: Theme.textFaint
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontSm
            }

            Item { width: 1; height: 44 }

            Text {
                text: page.sessionObj ? page.sessionObj.statusText : ""
                color: Theme.textDim
                font.pixelSize: Theme.fontMd
            }
            Item { width: 1; height: 16 }

            // One calm progress thread that fills through the four stages.
            Rectangle {
                id: track
                width: parent.width; height: 3; radius: 2
                color: Theme.surface3
                Rectangle {
                    id: fill
                    height: parent.height; radius: 2
                    width: parent.width * progress
                    color: Theme.accent
                    Behavior on width { NumberAnimation { duration: 600; easing.type: Theme.easingEmph } }
                    // Soft leading glow, a quiet sign of life.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        width: 9; height: 9; radius: 5
                        color: Theme.accent
                        SequentialAnimation on opacity {
                            running: true; loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }
            Item { width: 1; height: 12 }
            Row {
                width: parent.width
                Repeater {
                    model: steps
                    delegate: Text {
                        required property int index
                        required property string modelData
                        width: track.width / 4
                        horizontalAlignment: index === 0 ? Text.AlignLeft
                                           : index === 3 ? Text.AlignRight : Text.AlignHCenter
                        text: modelData
                        color: stage === index ? Theme.accent : stage > index ? Theme.textDim : Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        font.weight: stage === index ? Font.Medium : Font.Normal
                        Behavior on color { ColorAnimation { duration: Theme.normal } }
                    }
                }
            }

            Item { width: 1; height: 40 }
            GhostButton {
                text: qsTr("Cancel")
                onClicked: page.sessionObj.disconnect()
            }
        }
    }

    // ---- Sign in ----
    Component {
        id: signInComp
        Card {
            id: card
            width: 380
            implicitHeight: col.implicitHeight + padding * 2
            padding: 28
            elevation: 1.2

            function submit() {
                if (!user.text.trim()) { user.error = true; shake.restart(); user.focusInput(); return }
                let u = user.text.trim(), d = page.sessionObj.domain
                const slash = u.indexOf("\\")
                if (slash > 0) { d = u.slice(0, slash); u = u.slice(slash + 1) }
                page.sessionObj.signIn(u, pass.text, d, remember.checked)
            }

            transform: Translate { id: shakeX }
            SequentialAnimation {
                id: shake
                NumberAnimation { target: shakeX; property: "x"; to: -10; duration: 50 }
                NumberAnimation { target: shakeX; property: "x"; to: 8; duration: 60 }
                NumberAnimation { target: shakeX; property: "x"; to: -5; duration: 60 }
                NumberAnimation { target: shakeX; property: "x"; to: 0; duration: 90; easing.type: Easing.OutBack }
            }
            Connections {
                target: page.sessionObj
                function onErrorTextChanged() { if (page.sessionObj.errorText) { shake.restart(); pass.focusInput() } }
            }
            Component.onCompleted: {
                if (page.sessionObj.errorText) shake.start()
                if (user.text) pass.focusInput(); else user.focusInput()
            }

            ColumnLayout {
                id: col
                width: card.width - card.padding * 2
                spacing: 16

                Rectangle {
                    width: 44; height: 44; radius: 13
                    color: Theme.accentSoft
                    Icon { anchors.centerIn: parent; name: "lock"; size: 20; color: Theme.accent }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: qsTr("Sign in to %1").arg(page.sessionObj.title)
                        color: Theme.text
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.DemiBold
                        width: parent.width
                        elide: Text.ElideRight
                    }
                    Text {
                        text: page.sessionObj.host + (page.sessionObj.port !== 3389 ? ":" + page.sessionObj.port : "")
                        color: Theme.textFaint
                        font.family: Theme.monoFamily
                        font.pixelSize: Theme.fontSm
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    visible: page.sessionObj.errorText !== ""
                    implicitHeight: errText.implicitHeight + 18
                    radius: Theme.radius
                    color: Theme.dangerSoft
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 9
                        spacing: 8
                        Icon { name: "alert"; size: 14; color: Theme.danger }
                        Text {
                            id: errText
                            Layout.fillWidth: true
                            text: page.sessionObj.errorText
                            color: Theme.danger
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }

                Field {
                    id: user
                    Layout.fillWidth: true
                    label: qsTr("Username")
                    placeholder: qsTr("DOMAIN\\user or user")
                    text: (page.sessionObj.domain ? page.sessionObj.domain + "\\" : "") + page.sessionObj.username
                    input.onTextChanged: error = false
                    onAccepted: pass.focusInput()
                }
                Field {
                    id: pass
                    Layout.fillWidth: true
                    label: qsTr("Password")
                    password: true
                    onAccepted: card.submit()
                }
                Toggle {
                    id: remember
                    visible: page.sessionObj.hostId !== ""
                    checked: true
                    label: qsTr("Remember in keychain")
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 10
                    GhostButton { text: qsTr("Cancel"); onClicked: page.closeRequested() }
                    PrimaryButton {
                        Layout.fillWidth: true
                        text: qsTr("Connect")
                        iconName: "arrow-right"
                        onClicked: card.submit()
                    }
                }
            }
        }
    }

    // ---- Certificate trust ----
    Component {
        id: certComp
        Card {
            id: cc
            width: 460
            implicitHeight: ccol.implicitHeight + padding * 2
            padding: 28
            elevation: 1.2
            readonly property var cert: page.sessionObj.certificate
            readonly property bool changed: cert.changed === true

            ColumnLayout {
                id: ccol
                width: cc.width - cc.padding * 2
                spacing: 14

                Rectangle {
                    width: 44; height: 44; radius: 13
                    color: cc.changed ? Theme.dangerSoft : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.14)
                    Icon { anchors.centerIn: parent; name: "shield"; size: 20; color: cc.changed ? Theme.danger : Theme.warning }
                    SequentialAnimation on scale {
                        running: cc.changed
                        loops: 3
                        NumberAnimation { to: 1.08; duration: 180 }
                        NumberAnimation { to: 1; duration: 220 }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: cc.changed ? qsTr("Server identity has changed") : qsTr("Verify server identity")
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                    text: cc.changed
                        ? qsTr("The certificate for %1 is different from the one you trusted before. This can mean the server was reconfigured — or that someone is intercepting the connection.").arg(cc.cert.host)
                        : qsTr("First connection to %1. Check that the fingerprint matches the server before trusting it.").arg(cc.cert.host)
                    color: Theme.textDim
                    font.pixelSize: Theme.fontMd
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: certGrid.implicitHeight + 24
                    radius: Theme.radius
                    color: Theme.surface2
                    border.color: Theme.border
                    GridLayout {
                        id: certGrid
                        anchors.fill: parent
                        anchors.margins: 12
                        columns: 2
                        columnSpacing: 12
                        rowSpacing: 6
                        Repeater {
                            model: [
                                [qsTr("Subject"), cc.cert.subject],
                                [qsTr("Issuer"), cc.cert.issuer],
                                [qsTr("Fingerprint"), cc.cert.fingerprint]
                            ]
                            delegate: Item {
                                required property var modelData
                                Layout.columnSpan: 2
                                Layout.fillWidth: true
                                implicitHeight: kv.implicitHeight
                                RowLayout {
                                    id: kv
                                    width: parent.width
                                    spacing: 12
                                    Text {
                                        Layout.preferredWidth: 72
                                        Layout.alignment: Qt.AlignTop
                                        text: modelData[0]
                                        color: Theme.textFaint
                                        font.pixelSize: Theme.fontSm
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData[1] || "—"
                                        color: Theme.text
                                        wrapMode: Text.WrapAnywhere
                                        font.family: Theme.monoFamily
                                        font.pixelSize: Theme.fontXs
                                    }
                                }
                            }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    spacing: 10
                    GhostButton { text: qsTr("Cancel"); onClicked: page.sessionObj.answerCertificate(0) }
                    Item { Layout.fillWidth: true }
                    GhostButton { text: qsTr("Trust once"); onClicked: page.sessionObj.answerCertificate(2) }
                    PrimaryButton {
                        text: qsTr("Always trust")
                        destructive: cc.changed
                        onClicked: page.sessionObj.answerCertificate(1)
                    }
                }
            }
        }
    }

    // ---- Ended / failed ----
    Component {
        id: endedComp
        Column {
            id: ended
            width: 400
            spacing: 18
            readonly property bool failed: page.st === RdpSession.Failed
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 56; height: 56; radius: 18
                color: parent.failed ? Theme.dangerSoft : Theme.surface2
                border.color: parent.failed ? "transparent" : Theme.border
                Icon { anchors.centerIn: parent; name: parent.parent.failed ? "alert" : "power"; size: 22
                    color: parent.parent.failed ? Theme.danger : Theme.textDim }
            }
            Column {
                width: parent.width
                spacing: 6
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: parent.parent.failed ? qsTr("Couldn’t connect") : qsTr("Disconnected")
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                    text: page.sessionObj.errorText || page.sessionObj.statusText
                    color: Theme.textDim
                    font.pixelSize: Theme.fontMd
                }
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                GhostButton { text: qsTr("Close tab"); onClicked: page.closeRequested() }
                GhostButton {
                    visible: ended.failed
                    text: qsTr("Enter credentials")
                    iconName: "lock"
                    onClicked: page.sessionObj.promptCredentials()
                }
                PrimaryButton { text: qsTr("Reconnect"); iconName: "refresh"; onClicked: page.sessionObj.reconnect() }
            }
        }
    }
}
