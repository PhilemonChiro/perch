import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// Prompts the user when a newer release is available. Instead of dumping the
// raw changelog, it parses the release notes into clean, categorised
// highlights (New / Improved / Fixed). A Download button opens the release page
// (it does not self-install); the raw markdown is shown only as a fallback when
// nothing could be parsed into highlights.
Popup {
    id: root
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 500
    implicitHeight: Math.min(col.implicitHeight + padding * 2, 620)
    padding: 24
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

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
        const groups = { new: [], improved: [], fixed: [], other: [] }
        const lines = ("" + notes).split(/\r?\n/)
        for (let raw of lines) {
            const line = raw.trim()
            if (!/^[-*]\s+/.test(line))          // only list items
                continue
            if (/full changelog/i.test(line))    // drop the compare-link footer
                continue
            const text = clean(line.replace(/^[-*]\s+/, ""))
            if (text.length < 3)
                continue
            // Sentence case the first letter for a consistent look.
            groups[kind(text)].push(text.charAt(0).toUpperCase() + text.slice(1))
        }
        const meta = [
            { key: "new",      label: qsTr("New"),      color: Theme.success },
            { key: "improved", label: qsTr("Improved"), color: Theme.accent },
            { key: "fixed",    label: qsTr("Fixed"),    color: Theme.warning },
            { key: "other",    label: qsTr("Changes"),  color: Theme.textFaint }
        ]
        const out = []
        for (const m of meta)
            if (groups[m.key].length)
                out.push({ label: m.label, color: m.color, items: groups[m.key] })
        return out
    }

    Overlay.modal: Rectangle { color: Theme.overlay }
    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.surface
        border.color: Theme.border
    }
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal }
        NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }

    ColumnLayout {
        id: col
        anchors.fill: parent
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Rectangle {
                width: 46; height: 46; radius: 13
                color: Theme.accentSoft
                Icon { anchors.centerIn: parent; name: "zap"; size: 20; color: Theme.accent }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: qsTr("Update available")
                    color: Theme.text; font.pixelSize: Theme.fontXl; font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Perch %1 is ready — you have %2")
                          .arg(UpdateChecker.latestVersion).arg(UpdateChecker.currentVersion)
                    color: Theme.textDim; font.pixelSize: Theme.fontSm; elide: Text.ElideRight
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: UpdateChecker.releaseName !== "" && UpdateChecker.releaseName !== UpdateChecker.latestVersion
            text: UpdateChecker.releaseName
            color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold
            wrapMode: Text.WordWrap
        }

        Text {
            text: qsTr("WHAT'S NEW")
            visible: root.highlights.length > 0
            color: Theme.textFaint; font.pixelSize: Theme.fontXs
            font.weight: Font.DemiBold; font.letterSpacing: 1.2
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            radius: Theme.radius
            color: Theme.bg
            border.color: Theme.border

            ScrollView {
                anchors.fill: parent
                anchors.margins: 14
                clip: true

                // Clean, categorised highlights.
                ColumnLayout {
                    width: root.width - root.padding * 2 - 28 - 2
                    spacing: 16
                    visible: root.highlights.length > 0

                    Repeater {
                        model: root.highlights
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 7

                            RowLayout {
                                spacing: 8
                                Rectangle {
                                    width: 7; height: 7; radius: 3.5
                                    color: modelData.color
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                Text {
                                    text: modelData.label
                                    color: Theme.textDim
                                    font.pixelSize: Theme.fontXs
                                    font.weight: Font.DemiBold
                                    font.letterSpacing: 0.6
                                }
                            }

                            Repeater {
                                model: modelData.items
                                delegate: RowLayout {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 15
                                    spacing: 8
                                    Text {
                                        text: "–"      // en dash bullet
                                        color: Theme.textFaint
                                        font.pixelSize: Theme.fontSm
                                        Layout.alignment: Qt.AlignTop
                                    }
                                    Text {
                                        text: modelData
                                        color: Theme.text
                                        font.pixelSize: Theme.fontSm
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                }
                            }
                        }
                    }
                }

                // Fallback: the raw notes, only when nothing parsed into highlights.
                TextArea {
                    visible: root.highlights.length === 0
                    readOnly: true
                    wrapMode: TextArea.Wrap
                    textFormat: TextEdit.MarkdownText
                    text: UpdateChecker.releaseNotes !== "" ? UpdateChecker.releaseNotes
                                                            : qsTr("No release notes provided.")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    background: null
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            GhostButton {
                text: qsTr("Skip this version")
                onClicked: { UpdateChecker.skip(); root.close() }
            }
            Item { Layout.fillWidth: true }
            GhostButton { text: qsTr("Later"); onClicked: root.close() }
            PrimaryButton {
                text: qsTr("Download")
                iconName: "arrow-right"
                onClicked: { UpdateChecker.openDownload(); root.close() }
            }
        }
    }
}
