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

    // Builds one entry per camera: standalone recorders count as themselves,
    // NVR recorders expand to one entry per channel.
    function buildUnstickCameraModel() {
        var model = [];
        try {
            var recs = rootWindow.hikvisionRecordersJson ? JSON.parse(rootWindow.hikvisionRecordersJson) : [];
            for (var i = 0; i < recs.length; i++) {
                var rec = recs[i];
                var ip = rec.ip;
                var httpP = parseInt(rec.httpPort) || (rec.port == 8000 ? 80 : rec.port) || 80;
                var user = rec.username || "";
                var pass = rec.password || "";
                var cams = rec.cameras || [];
                if (cams.length <= 1) {
                    // Standalone camera (recorder with a single channel): shown by
                    // recorder name, exactly like the "Connected Recorders" list.
                    model.push({
                        name: rec.name ? rec.name + " (" + ip + ")" : ip,
                        ip: ip,
                        httpPort: httpP,
                        user: user,
                        pass: pass,
                        channelId: cams.length === 1 ? cams[0].channelId : 1
                    });
                } else {
                    for (var j = 0; j < cams.length; j++) {
                        model.push({
                            name: (rec.name ? rec.name + " (" + ip + ")" : ip) + " - " + (cams[j].name ? cams[j].name : "Channel " + cams[j].channelId),
                            ip: ip,
                            httpPort: httpP,
                            user: user,
                            pass: pass,
                            channelId: cams[j].channelId
                        });
                    }
                }
            }
        } catch (e) {
            console.log("[Hikvision QML] buildUnstickCameraModel failed:", e);
        }
        unstickCameraModel = model;
    }

    Component {
        id: cameraSettingsComponent
        CameraSettingsWindow {}
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
                        implicitHeight: 32
                        color: "#0f151b"
                        border.color: backupCameraCombo.activeFocus ? "#ff7a00" : "#2a3540"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: backupCameraCombo.displayText
                        color: "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
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

    // ── Rule lines on the video stream: the camera's own switch (web page: VCA > Smart Event > General Settings > Metadata) ──
    property string ruleState: ""      // on, off, unavailable, error, or "" when not read yet
    property string ruleMessage: ""
    property string ruleForIp: ""
    Connections {
        target: HikvisionBackup
        function onRuleLinesResult(ip, state, message) {
            rootPanel.ruleForIp = ip;
            rootPanel.ruleState = state;
            rootPanel.ruleMessage = message;
        }
        function onRuleLinesAllProgress(name, done, total) {
            rootWindow.showNotice("Rule lines on the stream\n" + done + " of " + total + ": " + name, "#00f5d4", 0);
        }
        function onRuleLinesAllFinished(summary, ok) {
            rootWindow.showNotice(summary, ok ? "#00ff66" : "#ff3333", ok ? 10000 : 20000);
            rootPanel.ruleState = "";
            rootPanel.ruleMessage = "";
        }
    }

    ConfirmDialog {
        id: ruleAllConfirm
        property bool turnOn: true
        title: turnOn ? "Turn on rule lines for all cameras" : "Turn off rule lines for all cameras"
        iconSource: "qrc:/images/icon-warning.svg"
        message: (turnOn ? "Make every camera in the list draw its rule lines on the video stream?"
                         : "Make every camera in the list stop drawing its rule lines on the video stream?")
                 + "\n\n" + rootPanel.backupCameraModel.length + " camera(s) will be asked, one after the other, each on its own address. "
                 + "A camera without the switch is skipped. Nothing else on a camera is changed."
        onAccepted: HikvisionBackup.setRuleLinesAll(turnOn)
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
                text: "Rule lines on the video stream"
                color: "white"
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: true
            }

            ComboBox {
                id: ruleCameraCombo
                Layout.fillWidth: true
                enabled: !HikvisionBackup.ruleBusy
                model: rootPanel.backupCameraModel
                textRole: "name"
                onCurrentIndexChanged: {
                    rootPanel.ruleState = "";
                    rootPanel.ruleMessage = "";
                }
            }

            Text {
                property var sel: ruleCameraCombo.currentIndex >= 0 ? rootPanel.backupCameraModel[ruleCameraCombo.currentIndex] : null
                text: {
                    if (HikvisionBackup.ruleBusy)
                        return "Asking the camera...";
                    if (!sel)
                        return "No camera to choose.";
                    if (rootPanel.ruleForIp !== sel.ip || rootPanel.ruleState === "")
                        return "Not read yet. Press Check to see what this camera is set to.";
                    if (rootPanel.ruleState === "on")
                        return "ON: this camera draws its rule lines and targets on the stream. " + rootPanel.ruleMessage + ".";
                    if (rootPanel.ruleState === "off")
                        return "OFF: the stream is clean. " + rootPanel.ruleMessage + ".";
                    if (rootPanel.ruleState === "unavailable")
                        return "Not available: " + rootPanel.ruleMessage + ".";
                    return "Problem: " + rootPanel.ruleMessage + ".";
                }
                color: (rootPanel.ruleState === "on") ? "#00ff66" : ((rootPanel.ruleState === "error") ? "#ff6666" : "#8898a6")
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: ruleCheckBtn
                    text: "Check"
                    enabled: !HikvisionBackup.ruleBusy && ruleCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: ruleCheckBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleCheckBtn.pressed ? "#303a46" : (ruleCheckBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                    }
                    onClicked: HikvisionBackup.checkRuleLines(rootPanel.backupCameraModel[ruleCameraCombo.currentIndex].ip)
                }

                Button {
                    id: ruleOnBtn
                    text: "Turn on"
                    enabled: !HikvisionBackup.ruleBusy && ruleCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: ruleOnBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleOnBtn.pressed ? "#0a8f4a" : (ruleOnBtn.hovered ? "#14a24c" : "#118a41")
                        radius: 4
                    }
                    onClicked: HikvisionBackup.setRuleLines(rootPanel.backupCameraModel[ruleCameraCombo.currentIndex].ip, true)
                }

                Button {
                    id: ruleOffBtn
                    text: "Turn off"
                    enabled: !HikvisionBackup.ruleBusy && ruleCameraCombo.currentIndex >= 0
                    contentItem: Text {
                        text: ruleOffBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleOffBtn.pressed ? "#b01c18" : (ruleOffBtn.hovered ? "#e0241f" : "#c9201b")
                        radius: 4
                    }
                    onClicked: HikvisionBackup.setRuleLines(rootPanel.backupCameraModel[ruleCameraCombo.currentIndex].ip, false)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: ruleAllCheckBtn
                    text: "Check all"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0
                    contentItem: Text {
                        text: ruleAllCheckBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleAllCheckBtn.pressed ? "#303a46" : (ruleAllCheckBtn.hovered ? "#3a4550" : "#2a3540")
                        border.color: "#00f5d4"
                        radius: 4
                    }
                    onClicked: HikvisionBackup.checkRuleLinesAll()
                }

                Button {
                    id: ruleAllOnBtn
                    text: "Turn on all"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0
                    contentItem: Text {
                        text: ruleAllOnBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleAllOnBtn.pressed ? "#0a8f4a" : (ruleAllOnBtn.hovered ? "#14a24c" : "#118a41")
                        radius: 4
                    }
                    onClicked: { ruleAllConfirm.turnOn = true; ruleAllConfirm.open() }
                }

                Button {
                    id: ruleAllOffBtn
                    text: "Turn off all"
                    enabled: !HikvisionBackup.ruleBusy && rootPanel.backupCameraModel.length > 0
                    contentItem: Text {
                        text: ruleAllOffBtn.text
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }
                    background: Rectangle {
                        color: ruleAllOffBtn.pressed ? "#b01c18" : (ruleAllOffBtn.hovered ? "#e0241f" : "#c9201b")
                        radius: 4
                    }
                    onClicked: { ruleAllConfirm.turnOn = false; ruleAllConfirm.open() }
                }
            }

            Text {
                text: "Some cameras can draw the lines and boxes of their smart-event rules (line crossing, intrusion, region) on the video "
                      + "they send, including the sub-stream that KVision's smaller tiles use. This is the camera's own switch (in its web "
                      + "page: VCA > Smart Event > General Settings > Metadata > Enable Stream Rule and Sub-Stream). It is read first, only "
                      + "that switch is changed, and the camera is asked again to confirm. A camera without the switch says so. It uses each "
                      + "camera's own address and saved login, never the recorder's, and a refused login is not tried again."
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
