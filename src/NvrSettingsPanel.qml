import QtQuick 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import Qt.labs.settings 1.0
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Themes 1.0

ColumnLayout {
    id: rootPanel

    spacing: 12
    Layout.fillWidth: true
    Layout.margins: 10

    // Persist active recorders in application settings as JSON
    // Format: [{"ip":"...", "port":8000, "username":"...", "password":"...", "cameras":[{"channelId":1, "name":"..."}]}]
    property var recorders: []

    // Map of active session IPs (IP -> bool)
    property var activeSessionIps: ({})

    // Live UX feedback state
    property string statusMessage: ""
    property string statusColor: "#ff7a00"

    // Track NVR editing state
    property int editingIndex: -1
    property bool isDiscovering: false

    // LAN scan (Hikvision SADP Probe) results shown above the form
    property var scanResults: []
    property string scanNote: ""

    // The password actually sent for the add that is in progress. The form and the
    // session box can change before discovery returns, and the recorder must keep
    // the password that was used to log in. This value is not written to settings.
    property string pendingAddPassword: ""

    // Ticked, and a session password has been typed. An empty box leaves the form password in use.
    readonly property bool usingSessionPassword: useRecorderPasswordBox.checked && sessionPassField.text.length > 0

    function isRecorderAdded(ip) {
        for (var i = 0; i < recorders.length; ++i) {
            if (recorders[i] && recorders[i].ip === ip)
                return true;
        }
        return false;
    }

    // Bumped when a recorder's camera list arrives, so the results list is filtered again
    property int proxyRevision: 0

    // A camera behind a recorder that is already added is reached through that recorder, so it is not offered
    function visibleScanResults() {
        var rev = proxyRevision; // dependency for the binding
        var out = [];
        for (var i = 0; i < scanResults.length; ++i) {
            if (!HikvisionManager.isBehindKnownRecorder(scanResults[i].ip))
                out.push(scanResults[i]);
        }
        return out;
    }

    function startScan() {
        scanResults = [];
        scanNote = "";
        // Make sure each added recorder's camera list is known before the answers arrive
        for (var r = 0; r < recorders.length; ++r) {
            var rec = recorders[r];
            if (rec && rec.kind === "rtsp")
                continue;
            if (rec && rec.ip && rec.username && rec.password)
                HikvisionManager.prefetchProxyChannels(rec.ip, rec.httpPort || 80, rec.username, rec.password);
        }
        HikvisionProbe.start();
    }

    // Fills the form from a scan result; credentials are still typed by the user
    function useScanResult(dev) {
        ipField.text = dev.ip;
        portField.text = String(dev.sdkPort);
        httpPortField.text = String(dev.httpPort);
        if (nameField.text.trim().length === 0)
            nameField.text = dev.name;
        rootPanel.statusMessage = "";
        if (rootPanel.usingSessionPassword)
            nameField.forceActiveFocus();
        else
            passField.forceActiveFocus();
    }

    Connections {
        target: HikvisionProbe
        function onDeviceFound(device) {
            var list = rootPanel.scanResults.slice();
            list.push(device);
            rootPanel.scanResults = list;
        }
        function onScanFinished(count, networks, failed) {
            if (networks === 0)
                rootPanel.scanNote = qsTr("LNG_00593");
            else if (count === 0)
                rootPanel.scanNote = qsTr("LNG_00594").arg(networks);
            else if (failed > 0)
                rootPanel.scanNote = qsTr("LNG_00595").arg(networks).arg(networks + failed);
            else
                rootPanel.scanNote = "";
        }
    }


    // ── NvrCamerasWindow Component ──────────────────────────────────────
    // Declared here (outside the Repeater) so its QML creation context
    // belongs to rootPanel, NOT to any Repeater delegate.  When the
    // Repeater rebuilds its delegates (e.g. after loadRecorders()),
    // already-opened NvrCamerasWindow instances keep a valid context
    // because rootPanel is never destroyed.
    Component {
        id: nvrCamerasWindowComponent
        NvrCamerasWindow {}
    }


    // Creates a new, separate layout holding every camera of the given recorder,
    // in the smallest square-ish grid that fits them all, and switches to it.
    function generateGridForRecorder(recorderData) {
        var cams = (recorderData && recorderData.cameras) ? recorderData.cameras : [];
        if (cams.length === 0) {
            rootPanel.statusColor = "#ff3333";
            rootPanel.statusMessage = qsTr("No cameras found on this recorder.");
            return;
        }

        var cols = Math.ceil(Math.sqrt(cams.length));
        var rows = Math.ceil(cams.length / cols);

        var layout = layoutsCollectionModel.append();
        layout.visible = true;
        layout.size = Qt.size(cols, rows);
        layout.name = (recorderData.name ? recorderData.name : recorderData.ip) + " (" + cams.length + ")";

        for (var i = 0; i < cams.length; ++i) {
            var vp = layout.get(i);
            if (vp) {
                vp.url = "hikvision://" + recorderData.ip + "/" + cams[i].channelId;
                vp.secondaryUrl = vp.url;
                vp.volume = 0;
                vp.streamMode = rootWindow.streamModeForUrl(vp.url);
            }
        }

        stackLayout.currentIndex = layoutsCollectionModel.count - 1;
        rootPanel.statusColor = "#00f5d4";
        rootPanel.statusMessage = qsTr("Grid created: %1").arg(layout.name);
    }

    function openCamerasWindow(recorderData) {
        var win = nvrCamerasWindowComponent.createObject(rootWindow);
        win.recorder = JSON.parse(JSON.stringify(recorderData));
        win.show();
    }

    Component.onCompleted: {
        loadRecorders();
    }

    Connections {
        target: rootWindow
        function onHikvisionRecordersJsonChanged() {
            rootPanel.loadRecorders();
        }
    }

    Connections {
        target: HikvisionManager
        function onSessionStatusChanged(ip, loggedIn) {
            var states = Object.assign({}, rootPanel.activeSessionIps);
            states[ip] = loggedIn;
            rootPanel.activeSessionIps = states;
        }

        function onProxyChannelsReady(nvrIp, ok) {
            rootPanel.proxyRevision++;
        }

        function onDiscoveryFinished(ip, cameras, success, errorMsg) {
            if (!rootPanel.isDiscovering) return;
            rootPanel.isDiscovering = false;
            var savedPass = rootPanel.pendingAddPassword;
            rootPanel.pendingAddPassword = "";

            if (!success) {
                rootPanel.statusColor = "#ff3333";
                rootPanel.statusMessage = errorMsg || qsTr("LNG_00099");
                return;
            }

            var sdkP = parseInt(portField.text) || 8000;
            var httpP = parseInt(httpPortField.text) || 80;
            var rtspP = parseInt(rtspPortField.text) || 554;
            var rtspTransport = rtspTransportField.currentText === "TCP" ? "tcp" : (rtspTransportField.currentText === "UDP" ? "udp" : "");

            var newRecorder = {
                name: nameField.text.trim(),
                ip: ip,
                port: sdkP,
                sdkPort: sdkP,
                httpPort: httpP,
                rtspPort: rtspP,
                username: userField.text.trim(),
                password: savedPass,
                cameras: cameras,
                rtspTransport: rtspTransport
            };

            if (rootPanel.editingIndex === -1) {
                // ADD MODE
                var arr = rootPanel.recorders.slice();
                // Check if already added
                for (var idx = 0; idx < arr.length; idx++) {
                    if (arr[idx].ip === ip) {
                        arr.splice(idx, 1); // overwrite
                        break;
                    }
                }

                arr.push(newRecorder);
                rootPanel.recorders = arr;
                saveRecorders();

                // Generate a dynamic preset layout containing all discovered cameras
                var numCams = cameras.length;
                var gridSize = Math.ceil(Math.sqrt(numCams));
                
                var newLayout = layoutsCollectionModel.append();
                newLayout.visible = true;
                newLayout.size = Qt.size(gridSize, gridSize);
                newLayout.name = newRecorder.name !== "" ? newRecorder.name : ip;

                for (var i = 0; i < numCams; ++i) {
                    var vp = newLayout.get(i);
                    if (vp) {
                        // Store Hikvision URI
                        vp.url = "hikvision://" + newRecorder.ip + "/" + cameras[i].channelId;
                        vp.secondaryUrl = vp.url;
                        vp.volume = 0;
                        vp.streamMode = rootWindow.streamModeForUrl(vp.url);
                    }
                }

                // Force navigation to the newly created preset!
                stackLayout.currentIndex = layoutsCollectionModel.count - 1;

            } else {
                // EDIT MODE
                var arr2 = rootPanel.recorders.slice();
                var oldIp = arr2[rootPanel.editingIndex].ip;
                arr2[rootPanel.editingIndex] = newRecorder;
                rootPanel.recorders = arr2;
                saveRecorders();

                // Point tiles that still use this recorder at its new address. The rest of each layout is left as it is.
                for (var j = 0; j < layoutsCollectionModel.count; ++j) {
                    var l = layoutsCollectionModel.get(j);
                    if (l) {
                        for (var k2 = 0; k2 < l.count; ++k2) {
                            var vp = l.get(k2);
                            if (vp && vp.url && vp.url.indexOf("hikvision://") !== -1) {
                                var uriStr = String(vp.url);
                                var idx = uriStr.indexOf("hikvision://");
                                var content = uriStr.substring(idx + 12);
                                var parts = content.split("/");
                                var mainPart = parts[0];
                                var addrParts = mainPart.split("@");
                                var addrPort = (addrParts.length > 1) ? addrParts[1] : addrParts[0];
                                var ipPort = addrPort.split(":");
                                var vpIp = ipPort[0] || "";

                                if (vpIp === oldIp) {
                                    var chanId = parts.length > 1 ? parts[1] : "1";
                                    var newUrl2 = "hikvision://" + newRecorder.ip + "/" + chanId;
                                    if (vp.url === newUrl2) {
                                        vp.url = ""; // force refresh
                                    }
                                    vp.url = newUrl2;
                                    if (String(vp.secondaryUrl).indexOf("hikvision://") !== -1) {
                                        vp.secondaryUrl = newUrl2;
                                    }
                                }
                            }
                        }
                    }
                }
                rootPanel.editingIndex = -1;
            }

            // Clear fields & status
            nameField.text = "";
            ipField.text = "";
            portField.text = "8000";
            httpPortField.text = "80";
            rtspPortField.text = "554";
            userField.text = "admin";
            passField.text = "";
            rtspTransportField.currentIndex = 0;
            rootPanel.statusMessage = "";
        }
    }

    function initializeActiveSessions() {
        var states = {};
        for (var i = 0; i < recorders.length; i++) {
            var ip = recorders[i].ip;
            states[ip] = HikvisionManager.isLogged(ip);
        }
        activeSessionIps = states;
    }

    function loadRecorders() {
        try {
            var data = rootWindow.hikvisionRecordersJson;
            if (data) {
                recorders = JSON.parse(data);
            } else {
                recorders = [];
            }
            initializeActiveSessions();
        } catch(e) {
            console.log("[Hikvision QML Error] Failed to load recorders:", e);
            recorders = [];
        }
    }

    function saveRecorders() {
        try {
            rootWindow.hikvisionRecordersJson = JSON.stringify(recorders);
        } catch(e) {
            console.log("[Hikvision QML Error] Failed to save recorders:", e);
        }
    }

    function streamTypeLabel(url) {
        var scheme = Utils.streamScheme(url);
        if (scheme === "rtsp")
            return qsTr("RTSP stream");
        if (scheme === "http")
            return qsTr("HTTP stream");
        if (scheme === "https") {
            var path = String(url).split("#")[0].split("?")[0].toLowerCase();
            return path.indexOf(".m3u8") !== -1 ? qsTr("HLS stream") : qsTr("HTTPS stream");
        }
        return qsTr("Saved stream");
    }

    function rewriteStreamTiles(oldUrl, newUrl) {
        if (!oldUrl || oldUrl === newUrl || typeof layoutsCollectionModel === "undefined")
            return;
        for (var j = 0; j < layoutsCollectionModel.count; ++j) {
            var l = layoutsCollectionModel.get(j);
            if (!l)
                continue;
            for (var k = 0; k < l.count; ++k) {
                var vp = l.get(k);
                if (!vp)
                    continue;
                if (vp.url === oldUrl)
                    vp.url = newUrl;
                if (vp.secondaryUrl === oldUrl)
                    vp.secondaryUrl = newUrl;
            }
        }
    }

    function openStreamDialog(index) {
        rtspDialog.editingIndex = index;
        rtspDialog.errorText = "";
        if (index >= 0 && index < recorders.length && recorders[index].kind === "rtsp") {
            rtspNameField.text = recorders[index].name || "";
            rtspUrlField.text = Utils.decodeStreamForEdit(recorders[index].streamUrl || "");
            rtspDescField.text = recorders[index].description || "";
        } else {
            rtspDialog.editingIndex = -1;
            rtspNameField.text = "";
            rtspUrlField.text = "";
            rtspDescField.text = "";
        }
        rtspDialog.open();
    }

    function saveStream() {
        var name = rtspNameField.text.trim();
        var parsed = Utils.encodeStreamUrl(rtspUrlField.text);
        if (name.length === 0 || !parsed) {
            rtspDialog.errorText = qsTr("Enter a name and an rtsp://, http:// or https:// address with a host.");
            return;
        }
        var arr = recorders.slice();
        var editAt = rtspDialog.editingIndex;
        var oldUrl = "";
        if (editAt >= 0 && editAt < arr.length)
            oldUrl = arr[editAt].streamUrl || "";
        for (var i = 0; i < arr.length; ++i) {
            if (i === editAt)
                continue;
            if (arr[i] && arr[i].streamUrl === parsed.url) {
                rtspDialog.errorText = qsTr("That stream is already saved.");
                return;
            }
        }
        var entry = {
            // Legacy storage tag for every saved network stream, including HTTP and HTTPS.
            kind: "rtsp",
            name: name,
            description: rtspDescField.text.trim(),
            streamUrl: parsed.url,
            ip: parsed.host,
            cameras: [{ channelId: 1, name: name, customName: name }]
        };
        if (editAt >= 0 && editAt < arr.length) {
            arr[editAt] = entry;
            rewriteStreamTiles(oldUrl, parsed.url);
        } else {
            arr.push(entry);
        }
        recorders = arr;
        saveRecorders();
        rtspDialog.close();
    }

    Text {
        text: qsTr("LNG_00098")
        color: "white"
        font {
            pixelSize: 13
            bold: true
        }
        Layout.fillWidth: true
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
            enabled: !rootPanel.isDiscovering

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                // Same look as the Connect and Cancel buttons below: orange to start, grey to stop.
                Button {
                    id: rtspAddBtn
                    text: qsTr("Add Stream")
                    implicitWidth: 148
                    implicitHeight: 30
                    focusPolicy: Qt.NoFocus
                    Layout.alignment: Qt.AlignBottom
                    onClicked: rootPanel.openStreamDialog(-1)

                    contentItem: Text {
                        text: rtspAddBtn.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                    }

                    background: Rectangle {
                        radius: 4
                        color: rtspAddBtn.pressed ? "#d66600" : (rtspAddBtn.hovered ? "#ff8c00" : "#ff7a00")
                    }
                }

                Button {
                    id: scanBtn
                    text: HikvisionProbe.scanning ? qsTr("LNG_00592") : qsTr("LNG_00591")
                    implicitWidth: 120
                    implicitHeight: 30
                    focusPolicy: Qt.NoFocus
                    onClicked: HikvisionProbe.scanning ? HikvisionProbe.stop() : rootPanel.startScan()

                    contentItem: Text {
                        text: scanBtn.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    background: Rectangle {
                        radius: 4
                        color: HikvisionProbe.scanning
                               ? (scanBtn.pressed ? "#404040" : (scanBtn.hovered ? "#505050" : "#303030"))
                               : (scanBtn.pressed ? "#d66600" : (scanBtn.hovered ? "#ff8c00" : "#ff7a00"))
                    }

                    Layout.alignment: Qt.AlignBottom
                }

                Text {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.alignment: Qt.AlignBottom
                    text: rootPanel.scanNote
                    visible: text.length > 0 && !HikvisionProbe.scanning
                    color: "#ff7a00"
                    font.pixelSize: 10
                    wrapMode: Text.WordWrap
                }

                // Held only in this panel, which lives for the whole run. Not a Settings value.
                ColumnLayout {
                    spacing: 2
                    Layout.alignment: Qt.AlignBottom
                    Layout.preferredWidth: 340
                    Layout.minimumWidth: 0

                    RowLayout {
                        spacing: 8
                        Layout.fillWidth: true

                        Text {
                            text: "Recorder Password"
                            color: "#8898a6"
                            font.pixelSize: 10
                            Layout.alignment: Qt.AlignVCenter
                        }

                        CheckBox {
                            id: useRecorderPasswordBox
                            text: "Use Recorder Password"
                            checked: true
                            font.pixelSize: 10
                            padding: 0
                            spacing: 4
                            Layout.alignment: Qt.AlignVCenter

                            ToolTip.delay: Compact.toolTipDelay
                            ToolTip.timeout: 8000
                            ToolTip.visible: hovered
                            ToolTip.text: "Log in to each recorder you add with the password below. Cleared when KVision closes."
                        }
                    }

                    TextField {
                        id: sessionPassField
                        placeholderText: "••••••••"
                        echoMode: TextInput.Password
                        selectByMouse: true
                        Layout.fillWidth: true
                        implicitHeight: 30
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: sessionPassField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                    }
                }
            }

            ListView {
                id: scanList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 190)
                visible: count > 0
                clip: true
                spacing: 3
                model: { rootPanel.proxyRevision; return rootPanel.visibleScanResults(); }
                ScrollBar.vertical: ScrollBar {}

                delegate: Rectangle {
                    property bool added: rootPanel.isRecorderAdded(modelData.ip)
                    width: scanList.width
                    height: 40
                    radius: 4
                    color: rowArea.containsMouse ? "#24313d" : "#0f151b"
                    border.color: "#2a3540"
                    opacity: added ? 0.5 : 1.0

                    Column {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 8
                        spacing: 1

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            color: "white"
                            font.pixelSize: 11
                            text: (modelData.kind === "nvr" ? qsTr("LNG_00596") : qsTr("LNG_00597"))
                                  + "  " + modelData.name + "  " + modelData.ip
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            font.pixelSize: 9
                            color: (!modelData.activated || !modelData.sameSubnet) ? "#ff7a00" : "#8898a6"
                            text: {
                                var parts = [];
                                if (added)
                                    parts.push(qsTr("LNG_00598"));
                                if (!modelData.activated)
                                    parts.push(qsTr("LNG_00599"));
                                if (!modelData.sameSubnet)
                                    parts.push(qsTr("LNG_00600"));
                                parts.push(qsTr("LNG_00601").arg(modelData.interfaceIp));
                                if (modelData.serial)
                                    parts.push(modelData.serial);
                                return parts.join("  |  ");
                            }
                        }
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !parent.added
                        onClicked: rootPanel.useScanResult(modelData)
                    }
                }
            }

            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true

                Text {
                    text: qsTr("LNG_00097")
                    color: "#8898a6"
                    font.pixelSize: 10
                }

                TextField {
                    id: nameField
                    placeholderText: qsTr("LNG_00097")
                    selectByMouse: true
                    Layout.fillWidth: true
                    color: "white"
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: nameField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                    onTextChanged: rootPanel.statusMessage = ""
                }
            }

            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true

                Text {
                    text: qsTr("LNG_00096")
                    color: "#8898a6"
                    font.pixelSize: 10
                }

                TextField {
                    id: ipField
                    placeholderText: "192.168.1.100"
                    selectByMouse: true
                    Layout.fillWidth: true
                    color: "white"
                    background: Rectangle {
                        color: "#0f151b"
                        radius: 4
                        border.color: ipField.activeFocus ? "#ff7a00" : "#2a3540"
                    }
                    onTextChanged: rootPanel.statusMessage = ""
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: qsTr("LNG_00532")
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    TextField {
                        id: portField
                        placeholderText: "8000"
                        text: "8000"
                        selectByMouse: true
                        Layout.fillWidth: true
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: portField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                        onTextChanged: rootPanel.statusMessage = ""
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: portField.hovered
                        ToolTip.text: "SDK / Server Port (default 8000)"
                    }
                }

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: qsTr("LNG_00533")
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    TextField {
                        id: httpPortField
                        placeholderText: "80"
                        text: "80"
                        selectByMouse: true
                        Layout.fillWidth: true
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: httpPortField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                        onTextChanged: rootPanel.statusMessage = ""
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: httpPortField.hovered
                        ToolTip.text: "HTTP / ISAPI Port (default 80)"
                    }
                }

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: qsTr("LNG_00534")
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    TextField {
                        id: rtspPortField
                        placeholderText: "554"
                        text: "554"
                        selectByMouse: true
                        Layout.fillWidth: true
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: rtspPortField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                        onTextChanged: rootPanel.statusMessage = ""
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: rtspPortField.hovered
                        ToolTip.text: "RTSP Port (default 554)"
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: qsTr("LNG_00094")
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    TextField {
                        id: userField
                        placeholderText: "admin"
                        text: "admin"
                        selectByMouse: true
                        Layout.fillWidth: true
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: userField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                        onTextChanged: rootPanel.statusMessage = ""
                    }
                }

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: qsTr("LNG_00093")
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    TextField {
                        id: passField
                        placeholderText: rootPanel.usingSessionPassword ? "Using recorder password" : "••••••••"
                        echoMode: TextInput.Password
                        enabled: !rootPanel.usingSessionPassword
                        selectByMouse: true
                        Layout.fillWidth: true
                        color: "white"
                        background: Rectangle {
                            color: "#0f151b"
                            radius: 4
                            border.color: passField.activeFocus ? "#ff7a00" : "#2a3540"
                        }
                        onTextChanged: rootPanel.statusMessage = ""
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1

                    Text {
                        text: "RTSP Transport"
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    ComboBox {
                        id: rtspTransportField
                        Layout.fillWidth: true
                        model: ["Auto (Global)", "TCP", "UDP"]
                        
                        background: Rectangle {
                            implicitHeight: 32
                            color: "#0f151b"
                            border.color: rtspTransportField.activeFocus ? "#ff7a00" : "#2a3540"
                            border.width: 1
                            radius: 4
                        }

                        contentItem: Text {
                            text: rtspTransportField.displayText
                            color: "white"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 10
                        }

                        delegate: ItemDelegate {
                            width: rtspTransportField.width
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
                                border.color: hovered ? "#ff7a00" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                        }

                        popup: Popup {
                            y: rtspTransportField.height + 2
                            width: rtspTransportField.width
                            implicitHeight: Math.min(320, rtspTransportField.popup.visible ? contentItem.implicitHeight : 0)
                            padding: 4

                            contentItem: ListView {
                                clip: true
                                implicitHeight: contentHeight
                                model: rtspTransportField.popup.visible ? rtspTransportField.delegateModel : null
                                currentIndex: rtspTransportField.highlightedIndex
                            }

                            background: Rectangle {
                                color: "#0f151b"
                                border.color: "#ff7a00"
                                border.width: 1
                                radius: 6
                            }
                        }
                    }
                }
            }

            // Live status message feedback
            Text {
                text: rootPanel.statusMessage
                color: rootPanel.statusColor
                font.pixelSize: 10
                font.bold: true
                visible: text !== ""
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: addBtn
                    text: rootPanel.isDiscovering ? qsTr("LNG_00092") : (rootPanel.editingIndex === -1 ? qsTr("LNG_00091") : qsTr("LNG_00090"))
                    Layout.fillWidth: true
                    highlighted: true

                    contentItem: RowLayout {
                        spacing: 8
                        Image {
                            source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='white' stroke-width='3' stroke-linecap='round'><path d='M12 2a10 10 0 1 0 10 10'></path></svg>"
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 16
                            visible: rootPanel.isDiscovering
                            fillMode: Image.PreserveAspectFit

                            RotationAnimation on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: rootPanel.isDiscovering
                            }
                        }
                        Text {
                            text: addBtn.text
                            font.bold: true
                            color: "white"
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    background: Rectangle {
                        color: addBtn.pressed ? "#d66600" : (addBtn.hovered ? "#ff8c00" : "#ff7a00")
                        radius: 4
                    }

                    onClicked: {
                        var pass = rootPanel.usingSessionPassword ? sessionPassField.text : passField.text;
                        if (ipField.text === "" || pass === "") {
                            rootPanel.statusColor = "#ff3333";
                            rootPanel.statusMessage = qsTr("LNG_00089");
                            return;
                        }

                        var ip = ipField.text.trim();
                        var sdkP = parseInt(portField.text) || 8000;
                        var httpP = parseInt(httpPortField.text) || 80;
                        var user = userField.text.trim();

                        rootPanel.statusColor = "#00f5d4"; // Cyan glowing text for loading
                        rootPanel.statusMessage = qsTr("LNG_00088");
                        rootPanel.pendingAddPassword = pass;
                        rootPanel.isDiscovering = true;

                        // Log in and fetch camera channels from NVR asynchronously
                        HikvisionManager.discoverCamerasAsync(ip, sdkP, httpP, user, pass);
                    }
                }

                Button {
                    id: cancelBtn
                    text: qsTr("LNG_00059")
                    visible: rootPanel.editingIndex !== -1
                    implicitWidth: 80
                    Layout.fillHeight: true

                    contentItem: Text {
                        text: cancelBtn.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    background: Rectangle {
                        color: cancelBtn.pressed ? "#404040" : (cancelBtn.hovered ? "#505050" : "#303030")
                        radius: 4
                    }

                    onClicked: {
                        rootPanel.editingIndex = -1;
                        nameField.text = "";
                        ipField.text = "";
                        portField.text = "8000";
                        httpPortField.text = "80";
                        rtspPortField.text = "554";
                        userField.text = "admin";
                        passField.text = "";
                        rtspTransportField.currentIndex = 0;
                        rootPanel.statusMessage = "";
                    }
                }
            }
        }
    }

    Text {
        text: qsTr("LNG_00087")
        color: "white"
        font {
            pixelSize: 13
            bold: true
        }
        Layout.fillWidth: true
        visible: rootPanel.recorders.length > 0
    }

    ColumnLayout {
        id: recordersListColumn
        Layout.fillWidth: true
        spacing: 6
        visible: rootPanel.recorders.length > 0

        Repeater {
            model: rootPanel.recorders
            delegate: Rectangle {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                height: 38
                color: "#1c242c"
                radius: 4
                border.color: "#2a3540"

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8

                    ColumnLayout {
                        spacing: 1
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        Layout.minimumWidth: 0

                        Text {
                            text: modelData.name ? modelData.name + " (" + modelData.ip + ")" : modelData.ip
                            color: "white"
                            font.bold: true
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: modelData.kind === "rtsp"
                                  ? (modelData.description ? modelData.description : rootPanel.streamTypeLabel(modelData.streamUrl))
                                  : qsTr("LNG_00086").arg(modelData.cameras ? modelData.cameras.length : 0)
                            color: "#8898a6"
                            font.pixelSize: 9
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    MouseArea {
                        id: statusArea
                        visible: modelData.kind !== "rtsp"
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: 4
                        Layout.preferredWidth: 100
                        implicitWidth: 100
                        implicitHeight: statusLayout.implicitHeight
                        hoverEnabled: true

                        RowLayout {
                            id: statusLayout
                            anchors.fill: parent
                            spacing: 6

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                antialiasing: true
                                color: (rootPanel.activeSessionIps[modelData.ip] || false) ? "#00ff66" : "#ff3333"
                            }

                            Text {
                                text: (rootPanel.activeSessionIps[modelData.ip] || false) ? qsTr("LNG_00085") : qsTr("LNG_00084")
                                color: (rootPanel.activeSessionIps[modelData.ip] || false) ? "#00ff66" : "#ff3333"
                                font.pixelSize: 9
                                font.bold: true
                            }
                        }

                        ToolTip {
                            delay: Compact.toolTipDelay
                            timeout: Compact.toolTipTimeout
                            visible: statusArea.containsMouse
                            text: qsTr("LNG_00083")
                        }
                    }

                    Button {
                        id: webBtn
                        visible: modelData.kind !== "rtsp"
                        hoverEnabled: true
                        implicitWidth: 30
                        implicitHeight: 30
                        Layout.fillWidth: false
                        Layout.preferredWidth: 30
                        Layout.alignment: Qt.AlignVCenter

                        contentItem: Image {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            source: {
                                var colorStr = webBtn.hovered ? "%2300f5d4" : "%238898a6";
                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6'></path><polyline points='15 3 21 3 21 9'></polyline><line x1='10' y1='14' x2='21' y2='3'></line></svg>";
                            }
                        }

                        background: Rectangle {
                            color: webBtn.pressed ? "#cc121214" : (webBtn.hovered ? "#3a4550" : "#1c242c")
                            radius: 15
                            border.color: webBtn.hovered ? "#00f5d4" : "#2a3540"
                            border.width: 1
                        }

                        onClicked: {
                            var hPort = modelData.httpPort || (modelData.port == 8000 ? 80 : modelData.port) || 80;
                            var url = "http://" + modelData.ip + (hPort == 80 ? "" : ":" + hPort);
                            WebBrowser.open(url);
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: webBtn.hovered
                        ToolTip.text: qsTr("LNG_00082")
                    }

                    Button {
                        id: gridBtn
                        visible: modelData.kind !== "rtsp"
                        hoverEnabled: true
                        implicitWidth: 30
                        implicitHeight: 30
                        Layout.fillWidth: false
                        Layout.preferredWidth: 30
                        Layout.alignment: Qt.AlignVCenter

                        contentItem: Image {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            source: {
                                var colorStr = gridBtn.hovered ? "%2300f5d4" : "%238898a6";
                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='3' y='3' width='7' height='7'></rect><rect x='14' y='3' width='7' height='7'></rect><rect x='14' y='14' width='7' height='7'></rect><rect x='3' y='14' width='7' height='7'></rect></svg>";
                            }
                        }

                        background: Rectangle {
                            color: gridBtn.pressed ? "#cc121214" : (gridBtn.hovered ? "#3a4550" : "#1c242c")
                            radius: 15
                            border.color: gridBtn.hovered ? "#00f5d4" : "#2a3540"
                            border.width: 1
                        }

                        onClicked: rootPanel.generateGridForRecorder(modelData)

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: gridBtn.hovered
                        ToolTip.text: qsTr("Generate Grid: new layout with all cameras of this recorder")
                    }

                    Button {
                        id: listBtn
                        visible: modelData.kind !== "rtsp"
                        hoverEnabled: true
                        implicitWidth: 30
                        implicitHeight: 30
                        Layout.fillWidth: false
                        Layout.preferredWidth: 30
                        Layout.alignment: Qt.AlignVCenter

                        contentItem: Image {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            source: {
                                var colorStr = listBtn.hovered ? "%2300f5d4" : "%238898a6";
                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='3' width='20' height='14' rx='2' ry='2'></rect><line x1='8' y1='21' x2='16' y2='21'></line><line x1='12' y1='17' x2='12' y2='21'></line></svg>";
                            }
                        }

                        background: Rectangle {
                            color: listBtn.pressed ? "#cc121214" : (listBtn.hovered ? "#3a4550" : "#1c242c")
                            radius: 15
                            border.color: listBtn.hovered ? "#00f5d4" : "#2a3540"
                            border.width: 1
                        }

                        onClicked: {
                            rootPanel.openCamerasWindow(modelData);
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: listBtn.hovered
                        ToolTip.text: qsTr("LNG_00081")
                    }

                    Button {
                        id: editBtn
                        hoverEnabled: true
                        implicitWidth: 30
                        implicitHeight: 30
                        Layout.fillWidth: false
                        Layout.preferredWidth: 30
                        Layout.alignment: Qt.AlignVCenter

                        contentItem: Image {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            source: {
                                var colorStr = editBtn.hovered ? "%23ff7a00" : "%238898a6";
                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='16 3 21 8 8 21 3 21 3 16 16 3'></polygon></svg>";
                            }
                        }

                        background: Rectangle {
                            color: editBtn.pressed ? "#cc121214" : (editBtn.hovered ? "#3a4550" : "#1c242c")
                            radius: 15
                            border.color: editBtn.hovered ? "#ff7a00" : "#2a3540"
                            border.width: 1
                        }

                        onClicked: {
                            if (modelData.kind === "rtsp") {
                                rootPanel.openStreamDialog(index);
                                return;
                            }
                            // Populate input fields for editing
                            nameField.text = modelData.name || "";
                            ipField.text = modelData.ip;
                            portField.text = modelData.sdkPort || modelData.port || "8000";
                            httpPortField.text = modelData.httpPort || (modelData.port == 8000 ? "80" : modelData.port) || "80";
                            rtspPortField.text = modelData.rtspPort || "554";
                            userField.text = modelData.username;
                            passField.text = modelData.password;
                            
                            if (modelData.rtspTransport === "tcp") {
                                rtspTransportField.currentIndex = 1;
                            } else if (modelData.rtspTransport === "udp") {
                                rtspTransportField.currentIndex = 2;
                            } else {
                                rtspTransportField.currentIndex = 0;
                            }
                            
                            rootPanel.editingIndex = index;
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: editBtn.hovered
                        ToolTip.text: qsTr("LNG_00080")
                    }

                    Button {
                        id: delBtn
                        hoverEnabled: true
                        implicitWidth: 30
                        implicitHeight: 30
                        Layout.fillWidth: false
                        Layout.preferredWidth: 30
                        Layout.alignment: Qt.AlignVCenter

                        contentItem: Image {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            source: {
                                var colorStr = delBtn.hovered ? "%23ff4d4d" : "%238898a6";
                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='3 6 5 6 21 6'></polyline><path d='M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2'></path><line x1='10' y1='11' x2='10' y2='17'></line><line x1='14' y1='11' x2='14' y2='17'></line></svg>";
                            }
                        }

                        background: Rectangle {
                            color: delBtn.pressed ? "#cc121214" : (delBtn.hovered ? "#3a4550" : "#1c242c")
                            radius: 15
                            border.color: delBtn.hovered ? "#ff4d4d" : "#2a3540"
                            border.width: 1
                        }

                        onClicked: {
                            deleteConfirmDialog1.targetIndex = index;
                            deleteConfirmDialog1.targetIp = modelData.ip;
                            deleteConfirmDialog1.targetIsRtsp = modelData.kind === "rtsp";
                            deleteConfirmDialog1.open();
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: delBtn.hovered
                        ToolTip.text: qsTr("LNG_00079")
                    }
                }
            }
        }
    }

    ConfirmDialog {
        id: deleteConfirmDialog1
        title: qsTr("LNG_00078")
        iconSource: "qrc:/images/icon-warning.svg"
        message: qsTr("LNG_00077")
        property int targetIndex: -1
        property string targetIp: ""
        property bool targetIsRtsp: false
        
        onAccepted: {
            deleteConfirmDialog2.targetIndex = targetIndex;
            deleteConfirmDialog2.targetIp = targetIp;
            deleteConfirmDialog2.targetIsRtsp = targetIsRtsp;
            deleteConfirmDialog2.open();
        }
    }

    ConfirmDialog {
        id: deleteConfirmDialog2
        title: qsTr("LNG_00076")
        iconSource: "qrc:/images/icon-warning.svg"
        message: qsTr("LNG_00075")
        property int targetIndex: -1
        property string targetIp: ""
        property bool targetIsRtsp: false
        
        onAccepted: {
            if (targetIndex >= 0 && targetIndex < rootPanel.recorders.length) {
                if (!targetIsRtsp)
                    HikvisionManager.logout(targetIp);
                
                // Remove from active recorders list
                var arr = rootPanel.recorders.slice();
                arr.splice(targetIndex, 1);
                rootPanel.recorders = arr;
                rootPanel.saveRecorders();
            }
        }
    }

    Dialog {
        id: rtspDialog
        title: editingIndex >= 0 ? qsTr("Edit stream") : qsTr("Add Stream")
        modal: true
        anchors.centerIn: parent
        width: 440
        leftPadding: 16
        rightPadding: 16
        topPadding: 16
        bottomPadding: 16
        property int editingIndex: -1
        property string errorText: ""

        background: Rectangle {
            color: "#1c242c"
            border.color: "#2a3540"
            border.width: 1
            radius: 8
        }

        header: Rectangle {
            color: "#0f151b"
            height: 42
            radius: 8
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 4
                color: "#0f151b"
            }
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                text: rtspDialog.title
                color: "#00f5d4"
                font.bold: true
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
            }
        }

        contentItem: ColumnLayout {
            spacing: 10

            Label { text: qsTr("Camera name"); color: "#8898a6"; font.pixelSize: 11 }
            TextField {
                id: rtspNameField
                selectByMouse: true
                Layout.fillWidth: true
                color: "white"
                font.pixelSize: 12
                placeholderText: qsTr("Workshop")
                background: Rectangle {
                    color: "#0f151b"
                    radius: 4
                    border.color: rtspNameField.activeFocus ? "#ff7a00" : "#2a3540"
                }
            }

            Label { text: qsTr("Stream URL"); color: "#8898a6"; font.pixelSize: 11 }
            TextField {
                id: rtspUrlField
                selectByMouse: true
                Layout.fillWidth: true
                color: "white"
                font.pixelSize: 12
                placeholderText: "rtsp://... or https://.../playlist.m3u8"
                background: Rectangle {
                    color: "#0f151b"
                    radius: 4
                    border.color: rtspUrlField.activeFocus ? "#ff7a00" : "#2a3540"
                }
            }

            Label { text: qsTr("Description (optional)"); color: "#8898a6"; font.pixelSize: 11 }
            TextField {
                id: rtspDescField
                selectByMouse: true
                Layout.fillWidth: true
                color: "white"
                font.pixelSize: 12
                background: Rectangle {
                    color: "#0f151b"
                    radius: 4
                    border.color: rtspDescField.activeFocus ? "#ff7a00" : "#2a3540"
                }
            }

            Text {
                text: rtspDialog.errorText
                visible: text.length > 0
                color: "#ff3333"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("LNG_00059")
                    implicitWidth: 80
                    onClicked: rtspDialog.close()
                    contentItem: Text {
                        text: parent.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#404040" : (parent.hovered ? "#505050" : "#303030")
                        radius: 4
                    }
                }
                Button {
                    text: qsTr("Save")
                    implicitWidth: 80
                    onClicked: rootPanel.saveStream()
                    contentItem: Text {
                        text: parent.text
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#d66600" : (parent.hovered ? "#ff8c00" : "#ff7a00")
                        radius: 4
                    }
                }
            }
        }
    }
}
