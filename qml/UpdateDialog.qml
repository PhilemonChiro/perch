import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// Prompts the user when a newer release is available. Instead of dumping the
// raw changelog, it parses the release notes into clean, categorised
// highlights (New / Improved / Fixed), taken from "## New" / "## Improved" /
// "## Fixed" headings when present. "Update now" downloads in-app with progress,
// then "Restart to update" installs and relaunches; without a downloadable asset
// it opens the release page. The raw markdown is shown only as a fallback when
// nothing could be parsed into highlights.
Popup {
    id: root
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 460
    implicitHeight: Math.min(col.implicitHeight, 640)
    padding: 0

    // Parsed highlight groups: [{ label, color, items: [string, ...] }, ...].
    property var highlights: buildHighlights(UpdateChecker.releaseNotes)

    // Turns a GitHub release body (markdown) into a few tidy, one-line
    // highlights grouped by kind. Strips links, PR/author suffixes, the
    // "Full Changelog" footer and markdown emphasis; keeps only bullet lines.
    function buildHighlights(notes) {
        if (!notes)
            return []
        const clean = (s) => s
            .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")              // [text](url) -> text
            .replace(/`([^`]+)`/g, "$1")                          // `code` -> code
            .replace(/\s+by\s+@[^\s]+(\s+in\s+#\d+)?/gi, "")       // "... by @user in #12"
            .replace(/\s*\(#\d+\)\s*$/g, "")                      // trailing "(#12)"
            .replace(/\s*#\d+\s*$/g, "")                          // trailing "#12"
            .replace(/[*_]{1,3}/g, "")                            // bold / italic markers
            .replace(/\s{2,}/g, " ")
            .trim()
        const kind = (t) => {
            const s = t.toLowerCase()
            if (/^(add|added|new|introduce|introduced|support|bring)\b/.test(s))
                return "new"
            if (/^(fix|fixed|resolve|resolved|correct|corrected|prevent|stop|repair)\b/.test(s)
                    || /\bfix(e[ds])?\b/.test(s))
                return "fixed"
            if (/^(improve|improved|update|updated|change|changed|refactor|polish|optimis|optimize|bump|redesign|speed|faster|tidy|clean)\b/.test(s))
                return "improved"
            return "other"
        }
        const heading = (t) => {
            const s = t.toLowerCase()
            if (/new|added|feature/.test(s)) return "new"
            if (/fix/.test(s)) return "fixed"
            if (/improve|better|change/.test(s)) return "improved"
            return ""
        }
        const groups = { new: [], improved: [], fixed: [], other: [] }
        const lines = ("" + notes).split(/\r?\n/)
        let section = ""
        for (let raw of lines) {
            const line = raw.trim()
            if (/^#{1,6}\s+/.test(line)) {      // "## Fixed" sets the group
                section = heading(line.replace(/^#+\s+/, ""))
                continue
            }
            if (!/^[-*]\s+/.test(line))          // only list items
                continue
            if (/full changelog/i.test(line))    // drop the compare-link footer
                continue
            const text = clean(line.replace(/^[-*]\s+/, ""))
            if (text.length < 3)
                continue
            // Sentence case the first letter for a consistent look.
            groups[section || kind(text)].push(text.charAt(0).toUpperCase() + text.slice(1))
        }
        const meta = [
            { key: "new",      label: qsTr("New"),      color: Theme.success },
            { key: "improved", label: qsTr("Improved"), color: Theme.accent },
            { key: "fixed",    label: qsTr("Fixed"),    color: Theme.warning },
            { key: "other",    label: qsTr("Changes"),  color: Theme.textDim }
        ]
        const out = []
        for (const m of meta)
            if (groups[m.key].length)
                out.push({ label: m.label, color: m.color, items: groups[m.key] })
        return out
    }

    readonly property bool busy: UpdateChecker.downloading
    readonly property bool ready: UpdateChecker.readyToInstall
    readonly property bool failed: UpdateChecker.downloadError !== ""
    // The download runs in the UpdateChecker singleton, so closing this dialog
    // only hides it: the download keeps going and the dialog reopens when it's
    // ready. So a click-outside or Escape is always allowed to dismiss.
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Overlay.modal: Rectangle { color: Theme.overlay }
    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.surface
        border.color: Theme.border
        // Soft accent wash behind the header.
        Rectangle {
            x: 1; y: 1
            width: parent.width - 2; height: 140
            radius: Theme.radiusLg
            gradient: Gradient {
                GradientStop { position: 0; color: Theme.accentSoft }
                GradientStop { position: 1; color: Theme.surface }
            }
        }
    }
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
        NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }

    component Chip: Rectangle {
        property alias label: chipText.text
        property bool strong: false
        height: 22; radius: 11
        width: chipText.implicitWidth + 18
        color: strong ? Theme.accentSoft : Theme.surface2
        border.color: strong ? "transparent" : Theme.border
        Text {
            id: chipText
            anchors.centerIn: parent
            color: parent.strong ? Theme.accent : Theme.textDim
            font.pixelSize: Theme.fontXs
            font.weight: parent.strong ? Font.DemiBold : Font.Medium
        }
    }

    ColumnLayout {
        id: col
        anchors.fill: parent
        spacing: 0

        // Header: brand mark, headline, "current -> new" version chips.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 26
            Layout.leftMargin: 26
            Layout.rightMargin: 26
            spacing: 0

            Rectangle {
                width: 52; height: 52; radius: 15
                color: Theme.surface
                border.color: Theme.border
                Icon { anchors.centerIn: parent; name: "brand"; size: 30; color: Theme.text }
            }
            Text {
                Layout.topMargin: 16
                Layout.fillWidth: true
                text: qsTr("A new Perch is ready")
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
                font.letterSpacing: -0.3
            }
            Text {
                Layout.topMargin: 4
                Layout.fillWidth: true
                text: qsTr("Here's what you get with this update.")
                color: Theme.textDim
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }
            Row {
                Layout.topMargin: 12
                spacing: 6
                Chip { label: "v" + UpdateChecker.currentVersion.replace(/^v/, "") }
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "arrow-right"; size: 12; color: Theme.textFaint }
                Chip { label: "v" + UpdateChecker.latestVersion.replace(/^v/, ""); strong: true }
            }
        }

        // Highlights, grouped New / Improved / Fixed.
        ScrollView {
            id: notes
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(notesCol.implicitHeight, 300)
            Layout.topMargin: 22
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                id: notesCol
                width: notes.availableWidth
                spacing: 18

                Repeater {
                    model: root.highlights
                    delegate: ColumnLayout {
                        id: group
                        required property var modelData
                        readonly property color tint: modelData.color
                        Layout.fillWidth: true
                        Layout.leftMargin: 26
                        Layout.rightMargin: 26
                        spacing: 9

                        Rectangle {
                            height: 20; radius: 6
                            width: tag.implicitWidth + 16
                            color: Qt.rgba(group.tint.r, group.tint.g, group.tint.b, Theme.dark ? 0.16 : 0.12)
                            Text {
                                id: tag
                                anchors.centerIn: parent
                                text: group.modelData.label.toUpperCase()
                                color: group.tint
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 0.9
                            }
                        }

                        Repeater {
                            model: group.modelData.items
                            delegate: RowLayout {
                                required property string modelData
                                Layout.fillWidth: true
                                spacing: 10
                                Rectangle {
                                    Layout.alignment: Qt.AlignTop
                                    Layout.topMargin: 1
                                    width: 16; height: 16; radius: 8
                                    color: group.tint
                                    Icon { anchors.centerIn: parent; name: "check"; size: 10; color: Theme.accentInk }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    color: Theme.text
                                    font.pixelSize: Theme.fontMd
                                    lineHeight: 1.15
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }

                // Fallback: the raw notes, only when nothing parsed into highlights.
                TextArea {
                    visible: root.highlights.length === 0
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    readOnly: true
                    wrapMode: TextArea.Wrap
                    textFormat: TextEdit.MarkdownText
                    text: UpdateChecker.releaseNotes !== "" ? UpdateChecker.releaseNotes
                                                            : qsTr("Bug fixes and improvements.")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    background: null
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 20
            Layout.leftMargin: 26
            Layout.rightMargin: 26
            text: qsTr("Takes about a minute. Your connections and saved queries stay just as they are.")
            color: Theme.textFaint
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        // Footer: actions, or download progress.
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 20
            Layout.leftMargin: 1
            Layout.rightMargin: 1
            Layout.bottomMargin: 1
            implicitHeight: 64
            color: Theme.surface2
            radius: Theme.radiusLg - 1
            // Square off the top corners; only the bottom ones are rounded.
            Rectangle { width: parent.width; height: Theme.radiusLg; color: parent.color }
            Rectangle { width: parent.width; height: 1; color: Theme.border }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 25
                anchors.rightMargin: 17
                spacing: 10

                // Idle: quiet skip link.
                Text {
                    visible: !root.busy && !root.ready && !root.failed
                    text: qsTr("Skip this version")
                    color: skipHover.hovered ? Theme.text : Theme.textFaint
                    font.pixelSize: Theme.fontSm
                    font.underline: skipHover.hovered
                    HoverHandler { id: skipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { UpdateChecker.skip(); root.close() } }
                }

                // Downloading / ready / error: progress with a status line.
                ColumnLayout {
                    visible: root.busy || root.ready || root.failed
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        Layout.fillWidth: true
                        text: root.failed ? UpdateChecker.downloadError
                            : root.ready ? qsTr("Downloaded. Restart to finish.")
                            : qsTr("Downloading…  %1%").arg(Math.round(UpdateChecker.downloadProgress * 100))
                        color: root.failed ? Theme.danger : Theme.textDim
                        font.pixelSize: Theme.fontSm
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        visible: !root.failed
                        Layout.fillWidth: true
                        height: 4; radius: 2
                        color: Theme.surface3
                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1, UpdateChecker.downloadProgress))
                            height: parent.height; radius: 2
                            color: root.ready ? Theme.success : Theme.accent
                            Behavior on width { NumberAnimation { duration: Theme.normal } }
                            Behavior on color { ColorAnimation { duration: Theme.normal } }
                        }
                    }
                }
                Item { visible: !(root.busy || root.ready || root.failed); Layout.fillWidth: true }

                GhostButton {
                    visible: !root.ready
                    text: root.busy ? qsTr("Cancel") : qsTr("Later")
                    onClicked: root.busy ? UpdateChecker.cancelDownload() : root.close()
                }
                PrimaryButton {
                    text: root.busy ? qsTr("Continue in background")
                        : root.ready ? qsTr("Restart now")
                        : root.failed ? qsTr("Try again")
                        : qsTr("Update now")
                    iconName: root.busy ? "" : root.ready ? "refresh" : "download"
                    onClicked: {
                        if (root.busy)
                            root.close()
                        else if (root.ready)
                            UpdateChecker.installAndRestart()
                        else if (UpdateChecker.canInstall)
                            UpdateChecker.startDownload()
                        else {
                            UpdateChecker.openDownload()
                            root.close()
                        }
                    }
                }
            }
        }
    }
}
