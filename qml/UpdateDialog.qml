import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Relay

// Prompts the user when a newer release is available, showing its notes and a
// Download button (which opens the release page — it does not self-install).
Popup {
    id: root
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 500
    implicitHeight: Math.min(col.implicitHeight + padding * 2, 620)
    padding: 24
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

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

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            radius: Theme.radius
            color: Theme.bg
            border.color: Theme.border
            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                TextArea {
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
