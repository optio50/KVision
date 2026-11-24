import QtQuick 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Themes 1.0

// The camera tools: save and restore a camera's own configuration, and the troubleshooting action.
// Anything declared inside this item is shown between the two (the Setup check box goes there).
ColumnLayout {
    id: rootPanel

    spacing: 12
    Layout.fillWidth: true

    default property alias betweenItems: betweenColumn.data


    // Flat camera list for the "Unstick event detection" tool.
    // Each entry: { name, ip, httpPort, user, pass, channelId }
    property var unstickCameraModel: []
    property bool unstickBusy: false
    property string unstickLabel: ""

    // Builds one entry per camera: a camera on its own (one or two lenses) stays one device,
    // and an NVR expands to one entry per channel. Standalone names are A–Z; NVR rows follow by channel.
    function buildUnstickCameraModel() {
        var standalone = [];
        var nvrRows = [];
        try {
            var recs = rootWindow.hikvisionRecordersJson ? JSON.parse(rootWindow.hikvisionRecordersJson) : [];
            for (var i = 0; i < recs.length; i++) {
                var rec = recs[i];
                var ip = rec.ip;
                var httpP = parseInt(rec.httpPort) || (rec.port == 8000 ? 80 : rec.port) || 80;
                var user = rec.username || "";
                var pass = rec.password || "";
                var cams = rec.cameras || [];
                var recLabel = rec.name ? rec.name + " (" + ip + ")" : ip;
                if (cams.length <= 2) {
                    if (cams.length <= 1) {
                        standalone.push({
                            name: recLabel,
                            ip: ip,
                            httpPort: httpP,
                            user: user,
                            pass: pass,
                            channelId: cams.length === 1 ? cams[0].channelId : 1,
                            standalone: true,
                            channel: 0
                        });
                    } else {
                        // Both lenses stay selectable. They sort with the other standalone cameras, by the name shown.
                        for (var d = 0; d < cams.length; d++) {
                            standalone.push({
                                name: recLabel + " - " + (cams[d].customName || cams[d].name || ("Channel " + cams[d].channelId)),
                                ip: ip,
                                httpPort: httpP,
                                user: user,
                                pass: pass,
                                channelId: cams[d].channelId,
                                standalone: true,
                                channel: 0
                            });
                        }
                    }
                } else {
                    for (var j = 0; j < cams.length; j++) {
                        nvrRows.push({
                            name: recLabel + " - " + (cams[j].customName || cams[j].name || ("Channel " + cams[j].channelId)),
                            ip: ip,
                            httpPort: httpP,
                            user: user,
                            pass: pass,
                            channelId: cams[j].channelId,
                            standalone: false,
                            channel: Utils.channelNumber(cams[j])
                        });
                    }
                }
            }
        } catch (e) {
            console.log("[Hikvision QML] buildUnstickCameraModel failed:", e);
        }
        standalone.sort(Utils.compareCameraChoice);
        nvrRows.sort(Utils.compareCameraChoice);
        unstickCameraModel = standalone.concat(nvrRows);
    }

    Component {
        id: cameraSettingsComponent
        CameraSettingsWindow {}
    }

    Component {
        id: cameraAddressComponent
        CameraAddressWindow {}
    }

    Component.onCompleted: {
        buildUnstickCameraModel();
        HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
    }

    Connections {
        target: rootWindow
        function onHikvisionRecordersJsonChanged() {
            rootPanel.buildUnstickCameraModel();
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
        }
    }

    Connections {
        target: HikvisionManager

        function onUnstickProgress(label, text) {
            if (label !== rootPanel.unstickLabel) return;
            rootWindow.showNotice(qsTr("Unsticking...") + "\n" + label + "\n" + text, "#00f5d4", 0);
        }

        function onUnstickFinished(label, result) {
            if (label !== rootPanel.unstickLabel) return;
            rootPanel.unstickBusy = false;
            if (result.indexOf("ok") === 0) {
                rootWindow.showNotice(qsTr("Done — event push restored") + "\n" + label + "\n" + result, "#00ff66", 6000);
            } else {
                rootWindow.showNotice(label + "\n" + result, "#ff3333", 10000);
            }
        }
    }

    // ── Camera backup: save each camera's own configuration (never the recorder's) ─────
    property var backupCameraModel: []
    property var restoreFileModel: []
    function refreshRestoreFiles() {
        var sel = backupCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[backupCameraCombo.currentIndex] : null;
        rootPanel.restoreFileModel = sel ? HikvisionBackup.listBackups(sel.ip) : [];
    }

    Connections {
        target: HikvisionBackup
        function onCamerasLoaded(cameras) {
            rootPanel.backupCameraModel = cameras;
            rootPanel.refreshRestoreFiles();
        }
        function onProgress(label, text) {
            rootWindow.showNotice(qsTr("Camera backup") + "\n" + label + "\n" + text, "#00f5d4", 0);
        }
        function onFinished(summary, ok) {
            rootWindow.showNotice(summary, ok ? "#00ff66" : "#ff3333", ok ? 8000 : 14000);
            rootPanel.refreshRestoreFiles();
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
        }
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: qsTr("Camera backup")
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ComboBox {
                    id: backupCameraCombo
                    Layout.fillWidth: true
                    onCurrentIndexChanged: rootPanel.refreshRestoreFiles()
                    model: rootPanel.backupCameraModel
                    textRole: "name"
                    enabled: !HikvisionBackup.busy

                    background: Rectangle {
                        implicitHeight: 34
                        color: "#1b2733"
                        border.color: backupCameraCombo.popup.visible || backupCameraCombo.hovered ? "#ff7a00" : "#5a6b7b"
                        border.width: 1
                        radius: 4
                    }
                    indicator: Text {
                        x: backupCameraCombo.width - width - 10
                        y: (backupCameraCombo.height - height) / 2
                        text: "\u25BE"
                        color: "#ff7a00"
                        font.pixelSize: 18
                    }
                    contentItem: Text {
                        text: backupCameraCombo.displayText
                        color: "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 28
                        elide: Text.ElideRight
                    }
                    delegate: ItemDelegate {
                        width: backupCameraCombo.width
                        height: 32
                        contentItem: Text {
                            text: modelData.name + "  (" + modelData.ip + ")"
                            color: hovered ? "#ff7a00" : "white"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 10
                        }
                        background: Rectangle {
                            color: hovered ? "#2a3540" : "transparent"
                            border.color: hovered ? "#ff7a00" : "transparent"
                            border.width: 1
                            radius: 4
                        }
                    }
                    popup: Popup {
                        y: backupCameraCombo.height + 2
                        width: backupCameraCombo.width
                        implicitHeight: Math.min(320, backupCameraCombo.popup.visible ? contentItem.implicitHeight : 0)
                        padding: 4
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: backupCameraCombo.popup.visible ? backupCameraCombo.delegateModel : null
                            currentIndex: backupCameraCombo.highlightedIndex
                        }
                        background: Rectangle {
                            color: "#0f151b"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }
                    }
                }

                Button {
                    id: backupOneBtn
                    text: qsTr("Back up")
                    enabled: !HikvisionBackup.busy && backupCameraCombo.currentIndex >= 0
                    Layout.fillHeight: true
                    contentItem: Text {
                        text: backupOneBtn.text
                        font.bold: true
                        color: backupOneBtn.enabled ? "white" : "#8898a6"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: !backupOneBtn.enabled ? "#303030" : (backupOneBtn.pressed ? "#d66600" : (backupOneBtn.hovered ? "#ff8c00" : "#ff7a00"))
                        radius: 4
                    }
                    onClicked: {
                        var sel = rootPanel.backupCameraModel[backupCameraCombo.currentIndex];
                        if (!sel)
                            return;
                        rootWindow.showNotice(qsTr("Camera backup") + "\n" + sel.name, "#00f5d4", 0);
                        HikvisionBackup.backupCamera(sel.ip, backupUserField.text, backupPassField.text);
                        backupPassField.text = "";
                    }
                }

                Button {
                    id: backupAllBtn
                    text: qsTr("Back up all cameras")
                    enabled: !HikvisionBackup.busy && rootPanel.backupCameraModel.length > 0
                    Layout.fillHeight: true
                    contentItem: Text {
                        text: backupAllBtn.text
                        font.bold: true
                        color: backupAllBtn.enabled ? "white" : "#8898a6"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: !backupAllBtn.enabled ? "#303030" : (backupAllBtn.pressed ? "#15803d" : (backupAllBtn.hovered ? "#22c55e" : "#16a34a"))
                        radius: 4
                    }
                    onClicked: {
                        rootWindow.showNotice(qsTr("Camera backup") + "\n" + qsTr("Backing up all cameras..."), "#00f5d4", 0);
                        HikvisionBackup.backupAll();
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                TextField {
                    id: backupUserField
                    text: "admin"
                    placeholderText: "admin"
                    selectByMouse: true
                    Layout.fillWidth: true
                    color: "white"
                    enabled: !HikvisionBackup.busy
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: backupUserField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                }

                TextField {
                    id: backupPassField
                    placeholderText: qsTr("Camera password")
                    echoMode: TextInput.Password
                    selectByMouse: true
                    Layout.fillWidth: true
                    color: "white"
                    enabled: !HikvisionBackup.busy
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: backupPassField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                }
            }

            Text {
                text: {
                    var sel = backupCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[backupCameraCombo.currentIndex] : null;
                    var login = sel ? (sel.login === "own" ? qsTr("Uses the login saved for this camera (%1).").arg(sel.user)
                                                           : qsTr("Uses the recorder's login (%1).").arg(sel.user)) : "";
                    return login + " " + qsTr("Each camera is backed up on its own address, never through the recorder. Files are saved in %1 and can only be read by you; treat them as sensitive.").arg(HikvisionBackup.backupDir());
                }
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            // Restore: only the backups of the camera picked above, one camera at a time.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ComboBox {
                    id: restoreFileCombo
                    Layout.fillWidth: true
                    enabled: !HikvisionBackup.busy
                    textRole: "label"
                    model: rootPanel.restoreFileModel

                    background: Rectangle {
                        implicitHeight: 32
                        color: "#0f151b"
                        border.color: restoreFileCombo.activeFocus ? "#ff7a00" : "#2a3540"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: rootPanel.restoreFileModel.length > 0 ? restoreFileCombo.displayText : qsTr("No backups of this camera yet")
                        color: rootPanel.restoreFileModel.length > 0 ? "white" : "#8898a6"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        elide: Text.ElideRight
                    }
                    delegate: ItemDelegate {
                        width: restoreFileCombo.width
                        height: 32
                        contentItem: Text {
                            text: modelData.label
                            color: hovered ? "#ff7a00" : "white"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 10
                        }
                        background: Rectangle {
                            color: hovered ? "#2a3540" : "transparent"
                            border.color: hovered ? "#ff7a00" : "transparent"
                            border.width: 1
                            radius: 4
                        }
                    }
                    popup: Popup {
                        y: restoreFileCombo.height + 2
                        width: restoreFileCombo.width
                        implicitHeight: Math.min(240, restoreFileCombo.popup.visible ? contentItem.implicitHeight : 0)
                        padding: 4
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: restoreFileCombo.popup.visible ? restoreFileCombo.delegateModel : null
                            currentIndex: restoreFileCombo.highlightedIndex
                        }
                        background: Rectangle {
                            color: "#0f151b"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }
                    }
                }

                Button {
                    id: restoreBtn
                    text: qsTr("Restore")
                    enabled: !HikvisionBackup.busy && rootPanel.restoreFileModel.length > 0 && restoreFileCombo.currentIndex >= 0
                    Layout.fillHeight: true
                    contentItem: Text {
                        text: restoreBtn.text
                        font.bold: true
                        color: restoreBtn.enabled ? "white" : "#8898a6"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: !restoreBtn.enabled ? "#303030" : (restoreBtn.pressed ? "#b91c1c" : (restoreBtn.hovered ? "#ef4444" : "#dc2626"))
                        radius: 4
                    }
                    onClicked: {
                        var cam = rootPanel.backupCameraModel[backupCameraCombo.currentIndex];
                        var file = rootPanel.restoreFileModel[restoreFileCombo.currentIndex];
                        if (!cam || !file)
                            return;
                        restoreConfirm1.camName = cam.name;
                        restoreConfirm1.camIp = cam.ip;
                        restoreConfirm1.fileName = file.file;
                        restoreConfirm1.fileLabel = file.label;
                        restoreConfirm1.open();
                    }
                }
            }

            Text {
                text: qsTr("Restore puts the chosen backup back on this camera only (the serial number must match). A fresh backup of the camera is taken first; if that fails, nothing is sent. The camera restarts and is offline for a minute or two.")
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // ── Camera addresses: each camera's own IP, and whether it is standalone or on an NVR ──
    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: qsTr("Camera addresses")
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            Text {
                text: qsTr("Every saved camera, its own address, and whether it is standalone or connected through an NVR.")
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Button {
                id: cameraAddressBtn
                text: qsTr("Camera addresses...")
                Layout.alignment: Qt.AlignLeft
                contentItem: Text {
                    text: cameraAddressBtn.text
                    color: "white"
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 10
                }
                background: Rectangle {
                    color: cameraAddressBtn.pressed ? "#303a46" : (cameraAddressBtn.hovered ? "#3a4550" : "#2a3540")
                    border.color: "#00f5d4"
                    radius: 4
                }
                onClicked: {
                    var w = cameraAddressComponent.createObject(rootWindow);
                    if (w)
                        w.show();
                }
                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: cameraAddressBtn.hovered
                ToolTip.text: qsTr("List every camera's address. Standalone cameras are reached directly. NVR cameras show the address the recorder reports for that channel.")
            }
        }
    }

    // ── Camera settings: a read only look at every camera's own settings (its own box, apart from Camera backup) ──
    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: qsTr("Camera settings")
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            Button {
                id: camSettingsBtn
                text: qsTr("Camera settings (read only)...")
                Layout.alignment: Qt.AlignLeft
                contentItem: Text {
                    text: camSettingsBtn.text
                    color: "white"
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 10
                }
                background: Rectangle {
                    color: camSettingsBtn.pressed ? "#303a46" : (camSettingsBtn.hovered ? "#3a4550" : "#2a3540")
                    border.color: "#00f5d4"
                    radius: 4
                }
                onClicked: {
                    var w = cameraSettingsComponent.createObject(rootWindow);
                    if (w)
                        w.show();
                }
                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: camSettingsBtn.hovered
                ToolTip.text: qsTr("Look at every camera's own settings, including the hours its speaker and light work. Nothing can be changed here.")
            }
        }
    }

    // ── On-screen target boxes and VCA lines, drawn by KVision. The camera is not changed. ──
    Component {
        id: vcaOverlayComponent
        VcaOverlayWindow {}
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: "Target boxes and VCA lines"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            Text {
                text: "KVision draws these on the tile from the camera's smart data. A tick takes effect at once. The camera is not changed."
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Button {
                id: vcaChooseBtn
                text: "Choose cameras..."
                contentItem: Text {
                    text: vcaChooseBtn.text
                    color: "white"
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 10
                }
                background: Rectangle {
                    color: vcaChooseBtn.pressed ? "#303a46" : (vcaChooseBtn.hovered ? "#3a4550" : "#2a3540")
                    border.color: "#00f5d4"
                    radius: 4
                }
                onClicked: {
                    var w = vcaOverlayComponent.createObject(rootWindow);
                    if (w)
                        w.show();
                }
                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: vcaChooseBtn.hovered
                ToolTip.text: qsTr("Tick the cameras that show target boxes and the cameras that show VCA lines. The same ticks as the right-click menu.")
            }
        }
    }

    // ── The stream saved for each camera on each layout. ──
    Component {
        id: streamSourceComponent
        StreamSourceWindow {}
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: "Video Stream per Layout"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            Text {
                text: "Open a layout to set Auto, Main, Sub or Third for each camera on that layout."
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Button {
                id: streamChooseBtn
                text: "Choose streams..."
                contentItem: Text {
                    text: streamChooseBtn.text
                    color: "white"
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 10
                }
                background: Rectangle {
                    color: streamChooseBtn.pressed ? "#303a46" : (streamChooseBtn.hovered ? "#3a4550" : "#2a3540")
                    border.color: "#00f5d4"
                    radius: 4
                }
                onClicked: {
                    var w = streamSourceComponent.createObject(rootWindow);
                    if (w)
                        w.show();
                }
                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: streamChooseBtn.hovered
                ToolTip.text: qsTr("Set the stream each camera uses on one layout.")
            }
        }
    }

    // ── Clock and firmware: read only (the camera's time against this computer's, and its firmware version) ──
    property var healthCard: ({})       // the last answer for the chosen camera, in the shape the setup check's list draws
    property string healthModel: ""     // its model, read by Check; empty until then
    property string healthNewest: ""    // the newest firmware the user noted for that model
    property string healthNewestDay: "" // the day that note was saved, like "14 Nov 2026"
    Connections {
        target: HikvisionBackup
        function onHealthResult(card) {
            // Only the camera chosen here (another camera can be checked again from the Check all window).
            var sel = healthCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[healthCameraCombo.currentIndex] : null;
            if (!sel || sel.ip !== card.key)
                return;
            rootPanel.healthCard = card;
            rootPanel.healthModel = card.model || "";
            rootPanel.healthNewest = rootPanel.healthModel !== "" ? HikvisionBackup.newestFirmware(rootPanel.healthModel) : "";
            rootPanel.healthNewestDay = rootPanel.healthModel !== "" ? HikvisionBackup.newestFirmwareDay(rootPanel.healthModel) : "";
            newestField.text = rootPanel.healthNewest;
        }
    }

    Component {
        id: healthWindowComponent
        CameraHealthWindow {}
    }
    property var healthWin: null
    function openHealthWindow() {
        if (rootPanel.healthWin) {
            // Already open: bring it forward and ask again.
            rootPanel.healthWin.show();
            rootPanel.healthWin.raise();
            rootPanel.healthWin.run();
            return;
        }
        var w = healthWindowComponent.createObject(rootWindow);
        if (w) {
            rootPanel.healthWin = w;
            w.show();
            w.run();
        }
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: "Camera clock and firmware"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            ComboBox {
                id: healthCameraCombo
                Layout.fillWidth: true
                enabled: !HikvisionBackup.ruleBusy
                model: rootPanel.backupCameraModel
                textRole: "name"
                onCurrentIndexChanged: {
                    rootPanel.healthCard = ({});
                    rootPanel.healthModel = "";
                    rootPanel.healthNewest = "";
                    rootPanel.healthNewestDay = "";
                    newestField.text = "";
                }

                background: Rectangle {
                    implicitHeight: 34
                    color: "#1b2733"
                    border.color: healthCameraCombo.popup.visible || healthCameraCombo.activeFocus ? "#ff7a00" : (healthCameraCombo.hovered ? "#ff7a00" : "#5a6b7b")
                    border.width: 1
                    radius: 4
                }
                indicator: Text {
                    x: healthCameraCombo.width - width - 10
                    y: (healthCameraCombo.height - height) / 2
                    text: "\u25BE"
                    color: "#ff7a00"
                    font.pixelSize: 18
                }
                contentItem: Text {
                    text: healthCameraCombo.displayText
                    color: healthCameraCombo.enabled ? "white" : "#8898a6"
                    font.pixelSize: 11
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 28
                    elide: Text.ElideRight
                }
                delegate: ItemDelegate {
                    width: healthCameraCombo.width
                    height: 32
                    contentItem: Text {
                        text: modelData.name + "  (" + modelData.ip + ")"
                        color: hovered ? "#ff7a00" : "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }
                    background: Rectangle {
                        color: hovered ? "#2a3540" : "transparent"
                        radius: 4
                    }
                }
                popup: Popup {
                    y: healthCameraCombo.height + 2
                    width: healthCameraCombo.width
                    implicitHeight: Math.min(320, healthCameraCombo.popup.visible ? contentItem.implicitHeight : 0)
                    padding: 4
                    contentItem: ListView {
                        clip: true
                        implicitHeight: contentHeight
                        model: healthCameraCombo.popup.visible ? healthCameraCombo.delegateModel : null
                        currentIndex: healthCameraCombo.highlightedIndex
                    }
                    background: Rectangle {
                        color: "#0f151b"
                        border.color: "#ff7a00"
                        border.width: 1
                        radius: 6
                    }
                }
            }

            Text {
                property var sel: healthCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[healthCameraCombo.currentIndex] : null
                visible: !healthCardView.visible
                text: HikvisionBackup.ruleBusy ? "Asking the camera..."
                      : (!sel ? "No camera to choose." : "Not read yet. Press Check to see this camera's clock and firmware.")
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            // The same card the detection setup check shows (one camera, opened).
            SetupCheckList {
                id: healthCardView
                visible: healthCameraCombo.currentIndex >= 0 && rootPanel.healthCard.key !== undefined
                         && rootPanel.healthCard.key === rootPanel.backupCameraModel[healthCameraCombo.currentIndex].ip
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                interactive: false
                results: rootPanel.healthCard.key !== undefined ? [rootPanel.healthCard] : []
                openKey: rootPanel.healthCard.key !== undefined ? rootPanel.healthCard.key : ""
                busy: HikvisionBackup.ruleBusy
                onRecheck: HikvisionBackup.checkHealth(key)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: healthCheckBtn
                    text: "Check"
                    enabled: !HikvisionBackup.ruleBusy && healthCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: healthCheckBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: healthCheckBtn.pressed ? "#303a46" : (healthCheckBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                    }
                    onClicked: HikvisionBackup.checkHealth(rootPanel.backupCameraModel[healthCameraCombo.currentIndex].ip)
                }

                Button {
                    id: healthAllBtn
                    text: "Check all"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0
                    contentItem: Text {
                        text: healthAllBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: healthAllBtn.pressed ? "#303a46" : (healthAllBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                    }
                    onClicked: rootPanel.openHealthWindow()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: rootPanel.healthModel !== ""

                Text {
                    text: qsTr("Newest firmware for %1:").arg(rootPanel.healthModel)
                    color: "#c8d2dc"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    Layout.maximumWidth: 260
                }

                TextField {
                    id: newestField
                    placeholderText: qsTr("for example V5.8.40")
                    selectByMouse: true
                    Layout.fillWidth: true
                    color: "white"
                    onAccepted: noteSaveBtn.clicked()
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: newestField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                }

                Button {
                    id: noteSaveBtn
                    text: newestField.text.trim() === "" ? qsTr("Remove note")
                          : (newestField.text.trim() === rootPanel.healthNewest ? qsTr("Confirm today") : qsTr("Save"))
                    enabled: rootPanel.healthModel !== "" && (newestField.text.trim() !== "" || rootPanel.healthNewest !== "")
                    contentItem: Text {
                        text: noteSaveBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: noteSaveBtn.pressed ? "#0a8f4a" : (noteSaveBtn.hovered ? "#14a24c" : "#118a41")
                        radius: 4
                        opacity: noteSaveBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: {
                        HikvisionBackup.setNewestFirmware(rootPanel.healthModel, newestField.text);
                        rootPanel.healthNewest = newestField.text.trim();
                        rootPanel.healthNewestDay = HikvisionBackup.newestFirmwareDay(rootPanel.healthModel);
                        rootWindow.showNotice(rootPanel.healthNewest === ""
                            ? qsTr("Note removed for %1").arg(rootPanel.healthModel)
                            : qsTr("Noted %1 as the newest firmware for %2, checked by hand on %3").arg(rootPanel.healthNewest).arg(rootPanel.healthModel).arg(rootPanel.healthNewestDay), "#00ff66", 5000);
                        if (!HikvisionBackup.ruleBusy && healthCameraCombo.currentIndex >= 0)
                            HikvisionBackup.checkHealth(rootPanel.backupCameraModel[healthCameraCombo.currentIndex].ip);
                    }
                }

                Button {
                    id: notePageBtn
                    text: qsTr("Open Hikvision page")
                    enabled: rootPanel.healthModel !== ""
                    contentItem: Text {
                        text: notePageBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: notePageBtn.pressed ? "#303a46" : (notePageBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                        opacity: notePageBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: {
                        // The search wants keyword, q and active=Products (an address that works: ...?keyword=ds-2cd2347&q=ds-2cd2347&active=Products).
                        // The term is the start of the model name: up to its first run of three or more digits, plus the generation
                        // (a letter and a digit: G2, G3) when there is one. DS-2CD2347G2-LSU/SL gives ds-2cd2347g2. The full name, with its
                        // -LSU/SL ending, may find nothing.
                        var m = /^[A-Za-z0-9-]*?\d{3,}(?:[A-Za-z]\d)?/.exec(rootPanel.healthModel);
                        var term = encodeURIComponent((m ? m[0] : rootPanel.healthModel.split("/")[0]).toLowerCase());
                        // WebBrowser.open uses the browser chosen in the general settings (Qt.openUrlExternally would use the system default).
                        WebBrowser.open("https://www.hikvision.com/en/search/?keyword=" + term + "&q=" + term + "&active=Products");
                    }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Opens Hikvision's own search for this model in your browser. Find the model's page, read the current firmware version there, and type it here.")
                }
            }

            Text {
                visible: rootPanel.healthModel !== ""
                text: rootPanel.healthNewest === "" ? qsTr("No newest firmware noted for this model yet.")
                      : (rootPanel.healthNewestDay !== ""
                         ? qsTr("Noted by hand: %1, last confirmed on %2. Press \"Confirm today\" after you look at Hikvision's page again.").arg(rootPanel.healthNewest).arg(rootPanel.healthNewestDay)
                         : qsTr("Noted by hand: %1 (the day was not recorded). Press \"Confirm today\" after you look at Hikvision's page again.").arg(rootPanel.healthNewest))
                color: rootPanel.healthNewest === "" ? "#ff6666" : "#8898a6"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Text {
                text: "Check shows one camera here. Check all opens a window with one card per camera. It shows the camera's own clock next to this computer's, and its firmware version. After a Check, type the newest firmware version you see on Hikvision's page for that model and press Save: a camera with an older version is then marked as \"update may be available\". (The cameras cannot say, and Hikvision's site cannot be read by a program, so this is a note you keep.) A clock that is more than two minutes off is "
                      + "flagged: event times will be wrong, and some cameras refuse the login when their time is far out. This only reads: nothing on a camera "
                      + "is changed, and a refused login is not tried again. Set the time in the camera's web page (System > Time Settings)."
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // ── Max bitrate: the video streams' own limit (web page: Video > Max. Bitrate). Sets one number on every stream of a kind. ──
    property var bitrateCard: ({})   // the last answer for the chosen camera, in the shape the setup check's list draws
    Connections {
        target: HikvisionBackup
        function onStreamBitrateResult(card) {
            var sel = bitrateCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[bitrateCameraCombo.currentIndex] : null;
            if (!sel || sel.ip !== card.key)
                return;
            rootPanel.bitrateCard = card;
        }
    }

    Component {
        id: bitrateWindowComponent
        CameraBitrateWindow {}
    }
    // Opens the all-cameras window. It starts at once: the confirm dialog below has already been answered when a value is to be written.
    function openBitrateWindow(kind, kbps) {
        var w = bitrateWindowComponent.createObject(rootWindow, { "kind": kind, "kbps": kbps });
        if (w) {
            w.show();
            w.run();
        }
    }
    readonly property int bitrateKind: bitrateKindCombo.currentIndex === 0 ? 2 : 1   // the first choice is the sub-stream
    readonly property string bitrateKindText: bitrateKindCombo.currentIndex === 0 ? "sub-stream" : "main stream"
    readonly property int bitrateValue: parseInt(bitrateField.text)

    ConfirmDialog {
        id: bitrateOneConfirm
        title: "Set max bitrate"
        iconSource: "qrc:/images/icon-warning.svg"
        property string camIp: ""
        property string camName: ""
        property int kind: 2
        property int kbps: 0
        message: "Set the " + (kind === 1 ? "main stream" : "sub-stream") + " max bitrate of " + camName + " (" + camIp + ") to " + kbps + " kbps?"
                 + "\n\nThis changes the camera's own video setting, on every stream of that kind it has (a two-lens camera has one per lens). "
                 + "The camera is read back to confirm, and nothing else in the stream is changed. A value the stream does not accept is skipped."
        onAccepted: HikvisionBackup.streamBitrate(camIp, kind, kbps)
    }

    ConfirmDialog {
        id: bitrateAllConfirm
        title: "Set max bitrate on all cameras"
        iconSource: "qrc:/images/icon-warning.svg"
        property int kind: 2
        property int kbps: 0
        message: "Set the " + (kind === 1 ? "main stream" : "sub-stream") + " max bitrate of EVERY camera in the list to " + kbps + " kbps?"
                 + "\n\n" + rootPanel.backupCameraModel.length + " camera(s) will be asked, one after the other, each on its own address. "
                 + "This changes each camera's own video setting. Each is read back to confirm and nothing else in the stream is changed. "
                 + "A camera that does not accept the value, or has no such stream, is left as it is and reported. What was changed is written to logs/BitrateChanges.log."
        onAccepted: rootPanel.openBitrateWindow(kind, kbps)
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: "Max bitrate of the video streams"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            ComboBox {
                id: bitrateCameraCombo
                Layout.fillWidth: true
                enabled: !HikvisionBackup.ruleBusy
                model: rootPanel.backupCameraModel
                textRole: "name"
                onCurrentIndexChanged: rootPanel.bitrateCard = ({})

                background: Rectangle {
                    implicitHeight: 34
                    color: "#1b2733"
                    border.color: bitrateCameraCombo.popup.visible || bitrateCameraCombo.activeFocus ? "#ff7a00" : (bitrateCameraCombo.hovered ? "#ff7a00" : "#5a6b7b")
                    border.width: 1
                    radius: 4
                }
                indicator: Text {
                    x: bitrateCameraCombo.width - width - 10
                    y: (bitrateCameraCombo.height - height) / 2
                    text: "\u25BE"
                    color: "#ff7a00"
                    font.pixelSize: 18
                }
                contentItem: Text {
                    text: bitrateCameraCombo.displayText
                    color: bitrateCameraCombo.enabled ? "white" : "#8898a6"
                    font.pixelSize: 11
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 28
                    elide: Text.ElideRight
                }
                delegate: ItemDelegate {
                    width: bitrateCameraCombo.width
                    height: 32
                    contentItem: Text {
                        text: modelData.name + "  (" + modelData.ip + ")"
                        color: hovered ? "#ff7a00" : "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }
                    background: Rectangle {
                        color: hovered ? "#2a3540" : "transparent"
                        radius: 4
                    }
                }
                popup: Popup {
                    y: bitrateCameraCombo.height + 2
                    width: bitrateCameraCombo.width
                    implicitHeight: Math.min(320, bitrateCameraCombo.popup.visible ? contentItem.implicitHeight : 0)
                    padding: 4
                    contentItem: ListView {
                        clip: true
                        implicitHeight: contentHeight
                        model: bitrateCameraCombo.popup.visible ? bitrateCameraCombo.delegateModel : null
                        currentIndex: bitrateCameraCombo.highlightedIndex
                    }
                    background: Rectangle {
                        color: "#0f151b"
                        border.color: "#ff7a00"
                        border.width: 1
                        radius: 4
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ComboBox {
                    id: bitrateKindCombo
                    Layout.preferredWidth: 150
                    enabled: !HikvisionBackup.ruleBusy
                    model: ["Sub-stream", "Main stream"]
                    onCurrentIndexChanged: rootPanel.bitrateCard = ({})
                    background: Rectangle {
                        implicitHeight: 34
                        color: "#1b2733"
                        border.color: bitrateKindCombo.popup.visible || bitrateKindCombo.activeFocus ? "#ff7a00" : (bitrateKindCombo.hovered ? "#ff7a00" : "#5a6b7b")
                        border.width: 1
                        radius: 4
                    }
                    indicator: Text {
                        x: bitrateKindCombo.width - width - 10
                        y: (bitrateKindCombo.height - height) / 2
                        text: "\u25BE"
                        color: "#ff7a00"
                        font.pixelSize: 18
                    }
                    contentItem: Text {
                        text: bitrateKindCombo.displayText
                        color: bitrateKindCombo.enabled ? "white" : "#8898a6"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 28
                        elide: Text.ElideRight
                    }
                    delegate: ItemDelegate {
                        width: bitrateKindCombo.width
                        height: 32
                        contentItem: Text {
                            text: modelData
                            color: hovered ? "#ff7a00" : "white"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 10
                        }
                        background: Rectangle {
                            color: hovered ? "#2a3540" : "transparent"
                            radius: 4
                        }
                    }
                    popup: Popup {
                        y: bitrateKindCombo.height + 2
                        width: bitrateKindCombo.width
                        implicitHeight: contentItem.implicitHeight
                        padding: 4
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: bitrateKindCombo.popup.visible ? bitrateKindCombo.delegateModel : null
                            currentIndex: bitrateKindCombo.highlightedIndex
                        }
                        background: Rectangle {
                            color: "#0f151b"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 4
                        }
                    }
                }

                TextField {
                    id: bitrateField
                    placeholderText: qsTr("max bitrate")
                    selectByMouse: true
                    Layout.preferredWidth: 110
                    color: "white"
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 32; top: 16384 }
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: bitrateField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                }

                Text {
                    text: "kbps"
                    color: "#c8d2dc"
                    font.pixelSize: 11
                }
                Item { Layout.fillWidth: true }
            }

            // The same card the detection setup check shows (one camera, opened).
            SetupCheckList {
                id: bitrateCardView
                visible: bitrateCameraCombo.currentIndex >= 0 && rootPanel.bitrateCard.key !== undefined
                         && rootPanel.bitrateCard.key === rootPanel.backupCameraModel[bitrateCameraCombo.currentIndex].ip
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                interactive: false
                results: rootPanel.bitrateCard.key !== undefined ? [rootPanel.bitrateCard] : []
                openKey: rootPanel.bitrateCard.key !== undefined ? rootPanel.bitrateCard.key : ""
                busy: HikvisionBackup.ruleBusy
                onRecheck: HikvisionBackup.streamBitrate(key, rootPanel.bitrateKind, 0)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: bitrateReadBtn
                    text: "Read"
                    enabled: !HikvisionBackup.ruleBusy && bitrateCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: bitrateReadBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: bitrateReadBtn.pressed ? "#303a46" : (bitrateReadBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                        opacity: bitrateReadBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: HikvisionBackup.streamBitrate(rootPanel.backupCameraModel[bitrateCameraCombo.currentIndex].ip, rootPanel.bitrateKind, 0)
                }

                Button {
                    id: bitrateReadAllBtn
                    text: "Read all"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0
                    contentItem: Text {
                        text: bitrateReadAllBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: bitrateReadAllBtn.pressed ? "#303a46" : (bitrateReadAllBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                        opacity: bitrateReadAllBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: rootPanel.openBitrateWindow(rootPanel.bitrateKind, 0)
                }

                Item { Layout.fillWidth: true }

                Button {
                    id: bitrateSetBtn
                    text: "Set on this camera"
                    enabled: !HikvisionBackup.ruleBusy && bitrateCameraCombo.currentIndex >= 0 && rootPanel.bitrateValue >= 32
                    contentItem: Text {
                        text: bitrateSetBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: bitrateSetBtn.pressed ? "#0a8f4a" : (bitrateSetBtn.hovered ? "#14a24c" : "#118a41")
                        radius: 4
                        opacity: bitrateSetBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: {
                        var cam = rootPanel.backupCameraModel[bitrateCameraCombo.currentIndex];
                        bitrateOneConfirm.camIp = cam.ip;
                        bitrateOneConfirm.camName = cam.name;
                        bitrateOneConfirm.kind = rootPanel.bitrateKind;
                        bitrateOneConfirm.kbps = rootPanel.bitrateValue;
                        bitrateOneConfirm.open();
                    }
                }

                Button {
                    id: bitrateSetAllBtn
                    text: "Set on all cameras"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0 && rootPanel.bitrateValue >= 32
                    contentItem: Text {
                        text: bitrateSetAllBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: bitrateSetAllBtn.pressed ? "#b01c18" : (bitrateSetAllBtn.hovered ? "#e0241f" : "#c9201b")
                        radius: 4
                        opacity: bitrateSetAllBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: {
                        bitrateAllConfirm.kind = rootPanel.bitrateKind;
                        bitrateAllConfirm.kbps = rootPanel.bitrateValue;
                        bitrateAllConfirm.open();
                    }
                }
            }

            Text {
                text: "Sets the max bitrate (the web page's Video > Max. Bitrate) of every stream of the chosen kind: sub-stream or main stream. A two-lens camera has "
                      + "one of each per lens and both are set. Each stream has its own limit (8192 or 16384 kbps on the cameras checked): a value outside it is skipped and "
                      + "reported, never changed. The number is the cap of a variable-rate stream and the rate of a constant-rate one; both are written. The whole stream "
                      + "setting is read first and written back with only those numbers changed, then read again to confirm. Read and Read all only look. Setting asks first, "
                      + "one camera uses its own address and saved login, never the recorder's, a refused login is not tried again, and every change is noted in logs/BitrateChanges.log. "
                      + "A lower value can make the picture blockier on a busy scene; the stream's own settings stay as they are otherwise."
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // ── Reboot a camera: for a camera that is not on a tile. The right-click "Reboot Camera" does the same for a tile. ──
    ConfirmDialog {
        id: rebootToolConfirm
        title: qsTr("Reboot camera")
        iconSource: "qrc:/images/icon-warning.svg"
        confirmButtonText: qsTr("Reboot")
        property string camIp: ""
        property string camName: ""
        message: qsTr("Restart %1 (%2)?").arg(camName).arg(camIp) + "\n\n"
                 + qsTr("The camera goes offline for a minute or two: its video stops and nothing is recorded from it meanwhile. Only this camera is restarted.")
        onAccepted: {
            rootWindow.showNotice(qsTr("Reboot camera") + "\n" + camName + "\n" + qsTr("asking the camera..."), "#ff9f43", 0);
            HikvisionBackup.rebootCamera(camIp);
        }
    }
    property string rebootResultText: ""
    property string rebootResultState: ""
    Connections {
        target: HikvisionBackup
        function onRebootResult(ip, state, message) {
            var sel = rebootCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[rebootCameraCombo.currentIndex] : null;
            if (sel && sel.ip === ip) {
                rootPanel.rebootResultState = state;
                rootPanel.rebootResultText = message;
            }
            var ok = (state === "started" || state === "sent");
            // The tile's own menu shows its notice; this one is for a restart started from this box.
            if (rebootToolConfirm.camIp === ip)
                rootWindow.showNotice(qsTr("Reboot camera") + "\n" + (sel && sel.ip === ip ? sel.name : ip) + "\n" + message, ok ? "#ff9f43" : "#ff3333", ok ? 12000 : 10000);
        }
    }

    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: "Reboot a camera"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            ComboBox {
                id: rebootCameraCombo
                Layout.fillWidth: true
                enabled: !HikvisionBackup.ruleBusy
                model: rootPanel.backupCameraModel
                textRole: "name"
                onCurrentIndexChanged: {
                    rootPanel.rebootResultState = "";
                    rootPanel.rebootResultText = "";
                }

                background: Rectangle {
                    implicitHeight: 34
                    color: "#1b2733"
                    border.color: rebootCameraCombo.popup.visible || rebootCameraCombo.activeFocus ? "#ff7a00" : (rebootCameraCombo.hovered ? "#ff7a00" : "#5a6b7b")
                    border.width: 1
                    radius: 4
                }
                indicator: Text {
                    x: rebootCameraCombo.width - width - 10
                    y: (rebootCameraCombo.height - height) / 2
                    text: "\u25BE"
                    color: "#ff7a00"
                    font.pixelSize: 18
                }
                contentItem: Text {
                    text: rebootCameraCombo.displayText
                    color: rebootCameraCombo.enabled ? "white" : "#8898a6"
                    font.pixelSize: 11
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    rightPadding: 28
                    elide: Text.ElideRight
                }
                delegate: ItemDelegate {
                    width: rebootCameraCombo.width
                    height: 32
                    contentItem: Text {
                        text: modelData.name + "  (" + modelData.ip + ")"
                        color: hovered ? "#ff7a00" : "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }
                    background: Rectangle {
                        color: hovered ? "#2a3540" : "transparent"
                        radius: 4
                    }
                }
                popup: Popup {
                    y: rebootCameraCombo.height + 2
                    width: rebootCameraCombo.width
                    implicitHeight: Math.min(320, rebootCameraCombo.popup.visible ? contentItem.implicitHeight : 0)
                    padding: 4
                    contentItem: ListView {
                        clip: true
                        implicitHeight: contentHeight
                        model: rebootCameraCombo.popup.visible ? rebootCameraCombo.delegateModel : null
                        currentIndex: rebootCameraCombo.highlightedIndex
                    }
                    background: Rectangle {
                        color: "#0f151b"
                        border.color: "#ff7a00"
                        border.width: 1
                        radius: 6
                    }
                }
            }

            Text {
                visible: rootPanel.rebootResultText !== ""
                text: rootPanel.rebootResultText
                color: (rootPanel.rebootResultState === "started" || rootPanel.rebootResultState === "sent") ? "#ff9f43" : "#ff6666"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: rebootToolBtn
                    text: "Reboot this camera"
                    enabled: !HikvisionBackup.ruleBusy && rebootCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: rebootToolBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: rebootToolBtn.pressed ? "#b01c18" : (rebootToolBtn.hovered ? "#e0241f" : "#c9201b")
                        radius: 4
                        opacity: rebootToolBtn.enabled ? 1.0 : 0.4
                    }
                    onClicked: {
                        var sel = rootPanel.backupCameraModel[rebootCameraCombo.currentIndex];
                        rootPanel.rebootResultState = "";
                        rootPanel.rebootResultText = "";
                        rebootToolConfirm.camIp = sel.ip;
                        rebootToolConfirm.camName = sel.name;
                        rebootToolConfirm.open();
                    }
                }
            }

            Text {
                text: "Restarts the chosen camera, after you confirm. It is offline for a minute or two: its video stops and nothing is recorded from it meanwhile. "
                      + "Only that camera is restarted, with its own address and saved login, one try; a recorder is never restarted. The same is in the right-click "
                      + "Quick tools menu of a tile."
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    ColumnLayout {
        id: betweenColumn
        Layout.fillWidth: true
        spacing: 12
    }

    // ── Troubleshooting: unstick a wedged event-detection push ──────────────────────
    Frame {
        Layout.fillWidth: true
        background: Rectangle {
            color: "#1c242c"
            radius: 6
            border.color: "#2a3540"
            border.width: 1
        }

        ColumnLayout {
            width: parent.width
            spacing: 8

            Text {
                text: qsTr("Troubleshooting")
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ComboBox {
                    id: unstickCameraCombo
                    Layout.fillWidth: true
                    model: rootPanel.unstickCameraModel
                    textRole: "name"

                    background: Rectangle {
                        implicitHeight: 32
                        color: "#0f151b"
                        border.color: unstickCameraCombo.activeFocus ? "#ff7a00" : "#2a3540"
                        border.width: 1
                        radius: 4
                    }

                    contentItem: Text {
                        text: unstickCameraCombo.displayText
                        color: "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }

                    delegate: ItemDelegate {
                        width: unstickCameraCombo.width
                        height: 32
                        contentItem: Text {
                            text: modelData.name
                            color: hovered ? "#ff7a00" : "white"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 10
                        }
                        background: Rectangle {
                            color: hovered ? "#2a3540" : "transparent"
                            border.color: hovered ? "#ff7a00" : "transparent"
                            border.width: 1
                            radius: 4
                        }
                    }

                    popup: Popup {
                        y: unstickCameraCombo.height + 2
                        width: unstickCameraCombo.width
                        implicitHeight: Math.min(320, unstickCameraCombo.popup.visible ? contentItem.implicitHeight : 0)
                        padding: 4

                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: unstickCameraCombo.popup.visible ? unstickCameraCombo.delegateModel : null
                            currentIndex: unstickCameraCombo.highlightedIndex
                        }

                        background: Rectangle {
                            color: "#0f151b"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }
                    }
                }

                Button {
                    id: unstickBtn
                    text: qsTr("Unstick event detection")
                    enabled: !rootPanel.unstickBusy
                    Layout.fillHeight: true

                    contentItem: Text {
                        text: unstickBtn.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    background: Rectangle {
                        color: unstickBtn.pressed ? "#d66600" : (unstickBtn.hovered ? "#ff8c00" : "#ff7a00")
                        radius: 4
                    }

                    onClicked: {
                        var sel = (unstickCameraCombo.currentIndex >= 0)
                                  ? rootPanel.unstickCameraModel[unstickCameraCombo.currentIndex]
                                  : null;
                        if (!sel) {
                            rootPanel.statusColor = "#ff3333";
                            rootPanel.statusMessage = qsTr("Select a camera first");
                            return;
                        }
                        rootPanel.unstickBusy = true;
                        rootPanel.unstickLabel = sel.name;
                        rootWindow.showNotice(qsTr("Unsticking...") + "\n" + sel.name, "#00f5d4", 0);
                        HikvisionManager.unstickEventDetectionAsync(sel.ip, sel.httpPort, sel.user, sel.pass, sel.channelId, sel.name);
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: unstickBtn.hovered
                    ToolTip.text: qsTr("Unstick event detection")
                }
            }

            Text {
                text: qsTr("Undoes the \"event push to a channel\" setting that can wedge after camera reinstallation or network issues. Requires Hikvision firmware version supporting this feature.")
                color: "#8898a6"
                font.pixelSize: 9
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    ConfirmDialog {
        id: restoreConfirm1
        title: qsTr("Restore camera configuration")
        iconSource: "qrc:/images/icon-warning.svg"
        property string camName: ""
        property string camIp: ""
        property string fileName: ""
        property string fileLabel: ""
        message: qsTr("Replace the settings of %1 (%2) with the backup from %3?").arg(camName).arg(camIp).arg(fileLabel)
        onAccepted: restoreConfirm2.open()
    }

    ConfirmDialog {
        id: restoreConfirm2
        title: qsTr("Are you sure?")
        iconSource: "qrc:/images/icon-warning.svg"
        message: qsTr("%1 will restart and be offline for a minute or two. Its current settings are saved first as a new backup. Continue?").arg(restoreConfirm1.camName)
        onAccepted: {
            rootWindow.showNotice(qsTr("Restoring camera") + "\n" + restoreConfirm1.camName, "#ff9f43", 0);
            HikvisionBackup.restoreCamera(restoreConfirm1.camIp, restoreConfirm1.fileName, backupUserField.text, backupPassField.text);
            backupPassField.text = "";
        }
    }
}
