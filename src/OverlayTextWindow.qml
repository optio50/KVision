import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0

// Settings for putting a value from an MQTT broker (an outside temperature, say) into one of a camera's on-screen text
// overlays, refreshed every few minutes. Off until switched on. It is the one place KVision writes to a camera, and it
// changes only the text of the slot chosen here.
Window {
    id: win

    width: 560
    height: 780
    minimumWidth: 500
    minimumHeight: 740
    color: "#0f151b"
    title: qsTr("Overlay text from MQTT")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    property var cameras: [] // { label, ip, httpPort, user, pass }
    property string testResult: ""
    property bool testOk: false
    property string savedCamera: "" // the address saved earlier, kept visible when it is no longer in the list
    readonly property bool haveCamera: cameraBox.currentIndex >= 0

    function load() {
        var s = {};
        try { s = JSON.parse(generalSettings.overlayText || "{}"); } catch (e) {}
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

    function save(quiet) {
        if (enabledBox.checked && !win.haveCamera) {
            win.testOk = false;
            win.testResult = qsTr("Choose the camera first. Nothing was saved.");
            return;
        }
        if (enabledBox.checked && (hostField.text.trim() === "" || topicField.text.trim() === "")) {
            win.testOk = false;
            win.testResult = qsTr("Fill in the broker address and the topic. Nothing was saved.");
            return;
        }
        var s = win.collect();
        generalSettings.overlayText = JSON.stringify(s);
        OverlayText.apply(s);
        // Say what the Save did, so a ticked and an unticked box are not mistaken for each other.
        if (quiet === true)
            return;
        win.testOk = true;
        win.testResult = s.enabled ? qsTr("Saved. The first update follows in a few seconds, then one every %1 minutes.").arg(s.minutes)
                                   : qsTr("Saved. Updates are switched off. Tick \"Keep the overlay text up to date\" and press Save to start them.");
    }

    Component.onCompleted: {
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
                out.push({ "label": (rec.name || recIp) + "  (" + recIp + ")", "ip": recIp, "channel": 1, "httpPort": http, "user": rec.username, "pass": rec.password });
                continue;
            }
            // A recorder: each channel is a camera of its own. The recorder says which address that camera has, and the
            // text is written there with the recorder's login (the same one the app already uses for it).
            for (var j = 0; j < cams.length; ++j) {
                var ch = parseInt(cams[j].channelId);
                var p = HikvisionManager.proxyCameraCached(recIp, http, rec.username, rec.password, ch);
                if (!p || !p.ip || p.ip === recIp)
                    continue;
                out.push({ "label": (rec.name || recIp) + " Ch. " + ch + "  " + (cams[j].customName || cams[j].name || ("Camera " + ch)) + "  (" + p.ip + ")",
                           "ip": p.ip, "channel": p.channel > 0 ? p.channel : 1, "httpPort": 80, "user": rec.username, "pass": rec.password });
            }
        }
        win.cameras = out;
        win.load();
    }

    Connections {
        target: OverlayText
        onClearDone: {
            win.testOk = ok;
            win.testResult = message;
            if (ok) {
                // The overlay is gone, so the updates are switched off too: nothing would write it back.
                enabledBox.checked = false;
                win.save(true);
            }
        }
        onTestDone: {
            win.testOk = ok;
            win.testResult = ok ? qsTr("Would write:  %1\n%2").arg(text).arg(message) : message;
        }
    }

    onClosing: {
        win.destroy();
        if (typeof rootWindow !== "undefined" && rootWindow)
            rootWindow.triggerGcDeferred();
    }

    ConfirmDialog {
        id: removeDialog
        parent: win.contentItem
        title: qsTr("Remove the overlay text?")
        iconSource: "qrc:/images/icon-trash.svg"
        message: qsTr("Text overlay number %1 will be taken off %2 (its text is deleted) and the updates will be switched off. The camera's date and time are not touched.").arg(slotBox.currentIndex + 1).arg(win.haveCamera ? cameraBox.currentText : "")
        confirmButtonText: qsTr("Remove")
        onAccepted: {
            win.testOk = true;
            win.testResult = qsTr("Removing...");
            OverlayText.clearSlot(win.collect());
        }
    }

    Item {
        anchors.fill: parent
        anchors.margins: 12

        ColumnLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: qsTr("Shows a value from an MQTT broker, such as the outside temperature, in one of a camera's on-screen text overlays and refreshes it. KVision changes only the text of the slot you choose, and only when the text has changed. It works while KVision is running. The camera needs a character overlay setting (most Hikvision cameras have one). If the slot you choose is not set up, KVision creates it. Slot 1 is the safest choice, and its old text is replaced.")
                color: "#8898a6"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                text: win.haveCamera
                      ? qsTr("Will write to:  %1,  text overlay %2").arg(cameraBox.currentText).arg(slotBox.currentIndex + 1)
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

                Text { text: qsTr("Name of the number"); color: "#eeeeee"; font.pixelSize: 12 }
                TextField {
                    id: fieldField
                    Layout.fillWidth: true
                    selectByMouse: true
                    placeholderText: "value"
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Some brokers send the reading inside JSON, for example {\"value\": 1.5}. Type the name of the number in it (here: value). If the message is only a number, such as 1.5, leave this empty. The reading must be in degrees Celsius.")
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
                    text: qsTr("Save")
                    onClicked: win.save()
                }
                Button {
                    text: qsTr("Remove from camera")
                    enabled: win.haveCamera
                    onClicked: removeDialog.open()
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: qsTr("Takes this text overlay off the camera (its text is deleted) and switches the updates off. Use it when you no longer want the text on the picture.")
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
                text: OverlayText.status !== "" ? qsTr("Last update:  %1").arg(OverlayText.status) : qsTr("Switched off. Tick the box above and press Save to start.")
                color: "#8898a6"
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }
    }
}
