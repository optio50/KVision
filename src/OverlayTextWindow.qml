import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0

// Settings for putting values from an MQTT broker (an outside temperature, say) into a camera's on-screen text overlays,
// refreshed every few minutes. Each entry is one topic going into one text overlay of one camera, so the list can hold as
// many as you like: fill in the form and press "Add / update" for each. Off until switched on. It is the one place KVision
// writes to a camera, and it changes only the text of the slots chosen here.
Window {
    id: win

    width: 640
    height: 900
    minimumWidth: 580
    minimumHeight: 520
    color: "#0f151b"
    title: qsTr("Overlay text from MQTT")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    property var cameras: [] // { label, ip, httpPort, user, pass }
    property string testResult: ""
    property bool testOk: false
    property string savedCamera: "" // the address saved earlier, kept visible when it is no longer in the list
    readonly property bool haveCamera: cameraBox.currentIndex >= 0
    property var entries: []        // the saved entries (see OverlayText in overlaytext.h)
    property string whenClosed: "keep"
    property int selected: -1       // the entry shown in the form; -1 is a new one
    property bool listReady: false  // false until the saved list has been read, so the closed-window choice cannot save an empty list over it
    property bool applyingClosed: false
    readonly property var statuses: OverlayText.statuses

    function cameraLabel(ip, channel) {
        for (var i = 0; i < win.cameras.length; ++i)
            if (win.cameras[i].ip === ip && win.cameras[i].channel === (channel > 0 ? channel : 1))
                return win.cameras[i].label;
        return ip || "";
    }

    function keyOf(e) {
        return OverlayText.entryKey(e);
    }

    function fillForm(s) {
        enabledBox.checked = s.enabled === true;
        hostField.text = s.host || "";
        portField.text = s.port > 0 ? String(s.port) : "1883";
        userField.text = s.user || "";
        passField.text = s.pass || "";
        topicField.text = s.topic || "";
        fieldField.text = s.field !== undefined ? s.field : "value";
        slotBox.currentIndex = Math.max(0, Math.min(3, (s.slot || 1) - 1));
        templateField.text = s.template || "Outside {temp} {unit}";
        unitBox.currentIndex = s.unit === "F" ? 1 : 0;
        decimalsBox.currentIndex = Math.max(0, Math.min(2, s.decimals !== undefined ? s.decimals : 1));
        minutesBox.value = s.minutes > 0 ? s.minutes : 5;
        var found = -1;
        for (var i = 0; i < win.cameras.length; ++i)
            if (win.cameras[i].ip === s.camera && win.cameras[i].channel === (s.camChannel > 0 ? s.camChannel : 1))
                found = i;
        cameraBox.currentIndex = found;
        win.savedCamera = s.camera || "";
    }

    function load() {
        var s = {};
        try { s = JSON.parse(OverlayText.migrate(generalSettings.overlayText || "{}")); } catch (e) {}
        win.entries = s.entries || [];
        win.whenClosed = s.whenClosed || "keep";
        win.applyingClosed = true;
        closedBox.currentIndex = win.whenClosed === "remove" ? 1 : (win.whenClosed === "stale" ? 2 : 0);
        win.applyingClosed = false;
        win.listReady = true;
        if (win.entries.length > 0)
            win.select(0);
        else
            win.newEntry(true);
    }

    function select(i) {
        win.selected = i;
        win.fillForm(win.entries[i]);
    }

    // An empty form for another entry. The broker and the text settings stay as they are, since the next entry is usually
    // another camera or another topic on the same broker.
    function newEntry(first) {
        win.selected = -1;
        cameraBox.currentIndex = -1;
        win.savedCamera = "";
        enabledBox.checked = true;
        if (first === true)
            win.fillForm({ "enabled": true });
        win.testResult = "";
    }

    function collect() {
        var cam = cameraBox.currentIndex >= 0 ? win.cameras[cameraBox.currentIndex] : null;
        return {
            "enabled": enabledBox.checked,
            "host": hostField.text.trim(),
            "port": parseInt(portField.text) || 1883,
            "user": userField.text,
            "pass": passField.text,
            "topic": topicField.text.trim(),
            "field": fieldField.text.trim(),
            "camera": cam ? cam.ip : "",
            "camChannel": cam ? cam.channel : 1,
            "httpPort": cam ? cam.httpPort : 80,
            "camUser": cam ? cam.user : "",
            "camPass": cam ? cam.pass : "",
            "slot": slotBox.currentIndex + 1,
            "template": templateField.text,
            "unit": unitBox.currentIndex === 1 ? "F" : "C",
            "decimals": decimalsBox.currentIndex,
            "minutes": minutesBox.value
        };
    }

    // Writes the list to the settings and makes the running entries match it.
    function persist() {
        if (!win.listReady)
            return;
        var json = JSON.stringify({ "version": 2, "whenClosed": win.whenClosed, "entries": win.entries });
        generalSettings.overlayText = json;
        generalSettings.overlayTextUserCleared = win.entries.length === 0;
        OverlayText.apply(json);
    }

    function save() {
        if (!win.haveCamera) {
            win.testOk = false;
            win.testResult = qsTr("Choose the camera first. Nothing was saved.");
            return;
        }
        if (enabledBox.checked && (hostField.text.trim() === "" || topicField.text.trim() === "")) {
            win.testOk = false;
            win.testResult = qsTr("Fill in the broker address and the topic. Nothing was saved.");
            return;
        }
        var e = win.collect();
        var key = win.keyOf(e);
        var list = win.entries.slice();
        var at = -1;
        for (var i = 0; i < list.length; ++i)
            if (win.keyOf(list[i]) === key)
                at = i;
        if (at >= 0)
            list[at] = e;
        else
            list.push(e);
        win.entries = list;
        win.selected = at >= 0 ? at : list.length - 1;
        win.persist();
        // Say what the save did, so a ticked and an unticked box are not mistaken for each other.
        win.testOk = true;
        var what = at >= 0 ? qsTr("Updated the entry for this camera and text overlay.") : qsTr("Added to the list.");
        win.testResult = what + " " + (e.enabled ? qsTr("The first update follows in a few seconds, then one every %1 minutes.").arg(e.minutes)
                                                  : qsTr("Its updates are switched off. Tick \"Keep the overlay text up to date\" and press the button again to start them."));
    }

    // Takes an entry out of the list without touching the camera.
    function dropEntry(key) {
        var list = [];
        for (var i = 0; i < win.entries.length; ++i)
            if (win.keyOf(win.entries[i]) !== key)
                list.push(win.entries[i]);
        win.entries = list;
        win.persist();
        if (list.length > 0)
            win.select(0);
        else
            win.newEntry(false);
    }

    function reloadCameras() {
        var list = [];
        try { list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]"); } catch (e) {}
        var out = [];
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            var cams = rec.cameras || [];
            var recIp = (rec.ip || "").split(":")[0];
            var http = parseInt(rec.httpPort) || 80;
            if (!rec.username || !rec.password)
                continue;
            if (cams.length <= 2) {
                // A camera with its own address is written to directly.
                out.push({ "label": (rec.name || recIp) + "  (" + recIp + ")", "ip": recIp, "channel": 1, "httpPort": http,
                           "user": rec.username, "pass": rec.password, "standalone": true, "sortChannel": 0 });
                continue;
            }
            // A recorder: each channel is a camera of its own. The recorder says which address that camera has, and the
            // text is written there with the recorder's login (the same one the app already uses for it).
            // The list is read in the background, so the first pass can be short and proxyChannelsReady fills it in.
            for (var j = 0; j < cams.length; ++j) {
                var ch = parseInt(cams[j].channelId);
                var p = HikvisionManager.proxyCameraCached(recIp, http, rec.username, rec.password, ch);
                if (!p || !p.ip || p.ip === recIp)
                    continue;
                out.push({ "label": (rec.name || recIp) + " Ch. " + ch + "  " + (cams[j].customName || cams[j].name || ("Camera " + ch)) + "  (" + p.ip + ")",
                           "ip": p.ip, "channel": p.channel > 0 ? p.channel : 1, "httpPort": 80, "user": rec.username, "pass": rec.password,
                           "standalone": false, "sortChannel": isNaN(ch) ? 0 : ch });
            }
        }
        out.sort(function(a, b) {
            return Utils.compareCameraChoice(
                { standalone: a.standalone, name: a.label, channel: a.sortChannel, ip: a.ip },
                { standalone: b.standalone, name: b.label, channel: b.sortChannel, ip: b.ip });
        });
        var chosen = cameraBox.currentIndex >= 0 ? win.cameras[cameraBox.currentIndex] : null;
        win.cameras = out;
        if (chosen) {
            var found = -1;
            for (var k = 0; k < out.length; ++k)
                if (out[k].ip === chosen.ip && out[k].channel === chosen.channel)
                    found = k;
            cameraBox.currentIndex = found;
        }
    }

    Component.onCompleted: {
        win.reloadCameras();
        win.load();
    }

    Connections {
        target: HikvisionManager
        function onProxyChannelsReady(nvrIp, ok) {
            if (ok)
                win.reloadCameras();
        }
    }

    Connections {
        target: OverlayText
        onClearDone: {
            win.testOk = ok;
            win.testResult = message;
            // The overlay is gone, so the entry goes too: nothing would write it back. When the camera could not be reached the
            // entry stays, so the text is not forgotten on the camera.
            if (ok)
                win.dropEntry(key);
        }
        onTestDone: {
            win.testOk = ok;
            win.testResult = ok ? qsTr("Would write:  %1\n%2").arg(text).arg(message) : message;
        }
    }

    onClosing: {
        win.destroy();
    }

    readonly property var chosen: win.selected >= 0 && win.selected < win.entries.length ? win.entries[win.selected] : null

    ConfirmDialog {
        id: removeDialog
        parent: win.contentItem
        title: qsTr("Remove the overlay text?")
        iconSource: "qrc:/images/icon-trash.svg"
        message: win.chosen ? qsTr("Text overlay number %1 will be taken off %2 (its text is deleted) and this entry will be removed from the list. The camera's date and time are not touched.").arg(win.chosen.slot).arg(win.cameraLabel(win.chosen.camera, win.chosen.camChannel)) : ""
        confirmButtonText: qsTr("Remove")
        onAccepted: {
            if (!win.chosen)
                return;
            win.testOk = true;
            win.testResult = qsTr("Removing...");
            OverlayText.clearSlot(win.chosen);
        }
    }

    ConfirmDialog {
        id: forgetDialog
        parent: win.contentItem
        title: qsTr("Forget this entry?")
        iconSource: "qrc:/images/icon-trash.svg"
        message: win.chosen ? qsTr("The entry for %1, text overlay %2, will be taken off the list and its updates stop. The camera is NOT touched, so the last text stays on its picture. Use this for a camera that is gone.").arg(win.cameraLabel(win.chosen.camera, win.chosen.camChannel)).arg(win.chosen.slot) : ""
        confirmButtonText: qsTr("Forget")
        onAccepted: {
            if (win.chosen)
                win.dropEntry(win.keyOf(win.chosen));
        }
    }

    // The form is taller than a small screen, so it scrolls.
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: formColumn.implicitHeight + 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}

        ColumnLayout {
            id: formColumn
            x: 12
            y: 12
            width: parent.width - 24 - 10
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: qsTr("Shows values from an MQTT broker, such as the outside temperature, in a camera's on-screen text overlays and keeps them up to date. Each entry is one topic going into one text overlay of one camera. Fill in the form and press Add for each one. KVision changes only the text of the overlays you choose, and only when the text has changed. A text overlay that the camera has not set up yet is created; its old text is replaced.")
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            Text { text: qsTr("Entries"); color: "#eeeeee"; font.pixelSize: 12; font.bold: true }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                color: "#141c24"
                border.color: "#2a3540"
                radius: 4
                clip: true

                Text {
                    anchors.centerIn: parent
                    visible: win.entries.length === 0
                    text: qsTr("Nothing yet. Fill in the form below and press \"Add / update\".")
                    color: "#8898a6"
                    font.pixelSize: 12
                }

                ListView {
                    id: entryList
                    anchors.fill: parent
                    anchors.margins: 2
                    model: win.entries
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Rectangle {
                        readonly property var e: modelData
                        readonly property string st: win.statuses[win.keyOf(e)] || ""
                        width: entryList.width
                        height: 48
                        color: index === win.selected ? "#1f3a40" : (rowArea.containsMouse ? "#1b2630" : "transparent")
                        radius: 3
                        MouseArea { id: rowArea; anchors.fill: parent; hoverEnabled: true; onClicked: win.select(index) }
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: win.cameraLabel(e.camera, e.camChannel) + "  -  " + qsTr("overlay %1").arg(e.slot) + (e.enabled ? "" : "  " + qsTr("(off)"))
                                color: e.enabled ? "#eeeeee" : "#8898a6"
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: e.topic + "  ->  " + (e.template || "")
                                color: "#8898a6"
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: !e.enabled ? qsTr("Switched off") : (st !== "" ? st : qsTr("Waiting for the first update"))
                                color: "#00f5d4"
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: win.haveCamera
                      ? (win.selected >= 0 ? qsTr("Editing:  %1,  text overlay %2") : qsTr("New entry for:  %1,  text overlay %2")).arg(cameraBox.currentText).arg(slotBox.currentIndex + 1)
                      : qsTr("No camera chosen yet. Nothing will be written.")
                color: win.haveCamera ? "#00f5d4" : "#e0a040"
                font.pixelSize: 12
                font.bold: true
                wrapMode: Text.Wrap
            }

            CheckBox {
                id: enabledBox
                text: qsTr("Keep the overlay text up to date")
                contentItem: Text { leftPadding: enabledBox.indicator.width + 6; text: enabledBox.text; color: "#eeeeee"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter }
            }

            GridLayout {
                columns: 2
                columnSpacing: 10
                rowSpacing: 6
                Layout.fillWidth: true

                Text { text: qsTr("Broker address"); color: "#eeeeee"; font.pixelSize: 12 }
                RowLayout {
                    Layout.fillWidth: true
                    TextField { id: hostField; Layout.fillWidth: true; placeholderText: "192.168.1.10"; selectByMouse: true }
                    Text { text: qsTr("port"); color: "#eeeeee"; font.pixelSize: 12 }
                    TextField { id: portField; Layout.preferredWidth: 70; selectByMouse: true; inputMethodHints: Qt.ImhDigitsOnly }
                }

                Text { text: qsTr("User (if needed)"); color: "#eeeeee"; font.pixelSize: 12 }
                TextField { id: userField; Layout.fillWidth: true; selectByMouse: true }

                Text { text: qsTr("Password (if needed)"); color: "#eeeeee"; font.pixelSize: 12 }
                TextField { id: passField; Layout.fillWidth: true; echoMode: TextInput.Password; selectByMouse: true }

                Text { text: qsTr("Topic"); color: "#eeeeee"; font.pixelSize: 12 }
                TextField { id: topicField; Layout.fillWidth: true; selectByMouse: true; placeholderText: "home/outside/temperature" }

                Text {
                    text: qsTr("Name of the number")
                    color: "#eeeeee"
                    font.pixelSize: 12
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 600
                        ToolTip.text: fieldField.ToolTip.text
                    }
                }
                TextField {
                    id: fieldField
                    Layout.fillWidth: true
                    selectByMouse: true
                    placeholderText: "value"
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("This is the name of the temperature inside the MQTT message. It is not a label on the camera. If the message is only a number, such as 21.5, leave this empty. If the message is JSON, type the name of the field that holds the number. For {\"value\": 21.5} the name is value. For {\"sensor\": {\"temp\": 21.5}} the name is sensor.temp. The number must already be in Celsius. The Celsius / Fahrenheit choice only changes how it is written on the camera.")
                }

                Text { text: qsTr("Camera"); color: "#eeeeee"; font.pixelSize: 12 }
                ComboBox {
                    id: cameraBox
                    Layout.fillWidth: true
                    model: win.cameras.map(function(c) { return c.label; })
                    currentIndex: -1
                    displayText: currentIndex >= 0 ? currentText : (win.savedCamera !== "" ? qsTr("%1 is not in the list. Choose a camera").arg(win.savedCamera) : qsTr("Choose a camera"))
                }

                Text { text: qsTr("Text overlay number"); color: "#eeeeee"; font.pixelSize: 12 }
                ComboBox {
                    id: slotBox
                    Layout.preferredWidth: 90
                    model: ["1", "2", "3", "4"]
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Which of the camera's four text overlays to write. Its text is replaced. If the camera has not got that overlay yet, KVision adds it.")
                }

                Text { text: qsTr("Text"); color: "#eeeeee"; font.pixelSize: 12 }
                TextField {
                    id: templateField
                    Layout.fillWidth: true
                    selectByMouse: true
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("{temp} is the number and {unit} is C or F, for example: Outside {temp} {unit}")
                }

                Text { text: qsTr("Show in"); color: "#eeeeee"; font.pixelSize: 12 }
                RowLayout {
                    ComboBox { id: unitBox; Layout.preferredWidth: 150; model: [qsTr("Celsius (C)"), qsTr("Fahrenheit (F)")] }
                    Text { text: qsTr("decimals"); color: "#eeeeee"; font.pixelSize: 12 }
                    ComboBox { id: decimalsBox; Layout.preferredWidth: 70; model: ["0", "1", "2"] }
                }

                Text { text: qsTr("Update every"); color: "#eeeeee"; font.pixelSize: 12 }
                RowLayout {
                    SpinBox { id: minutesBox; from: 1; to: 1440; value: 5; editable: true }
                    Text { text: qsTr("minutes"); color: "#eeeeee"; font.pixelSize: 12 }
                }

            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: qsTr("Test")
                    onClicked: { win.testResult = qsTr("Reading..."); win.testOk = true; OverlayText.test(win.collect()); }
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Reads the value and shows the text it would write. Nothing is written to the camera.")
                }
                Button {
                    text: win.selected >= 0 ? qsTr("Update") : qsTr("Add")
                    onClicked: win.save()
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Adds this to the list, or updates the entry that has the same camera and text overlay number, and starts it.")
                }
                Button {
                    text: qsTr("New entry")
                    onClicked: win.newEntry(false)
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Clears the camera so you can add another entry. The broker and the text settings stay, so a second camera takes a few clicks.")
                }
                Button {
                    text: qsTr("Remove from camera")
                    enabled: win.chosen !== null
                    onClicked: removeDialog.open()
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Takes this entry's text overlay off its camera (its text is deleted) and removes the entry from the list. Use it when you no longer want the text on the picture.")
                }
                Button {
                    text: qsTr("Forget")
                    enabled: win.chosen !== null
                    onClicked: forgetDialog.open()
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Takes the entry off the list without touching the camera. For a camera that is gone for good.")
                }
                Item { Layout.fillWidth: true }
            }

            Text {
                Layout.fillWidth: true
                visible: win.testResult !== ""
                text: win.testResult
                color: win.testOk ? "#2ecc71" : "#ff5a36"
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                text: win.entries.length === 0 ? qsTr("No entries yet.") : qsTr("The list above shows what each entry last did.")
                color: "#8898a6"
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#2a3540" }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: qsTr("When KVision is closed"); color: "#eeeeee"; font.pixelSize: 12; font.bold: true }
                ComboBox {
                    id: closedBox
                    Layout.preferredWidth: 300
                    model: [qsTr("Keep updating them"), qsTr("Remove them from the cameras"), qsTr("Show \"--\" instead of the number")]
                    onActivated: {
                        if (!win.listReady || win.applyingClosed)
                            return;
                        win.whenClosed = ["keep", "remove", "stale"][currentIndex];
                        win.persist();
                    }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("What the cameras show while the KVision window is closed. It applies to every entry in the list. This is done by the background service (the detection logger), so it must be running. When KVision starts again the text comes back by itself.")
                }
            }
        }
    }
}
