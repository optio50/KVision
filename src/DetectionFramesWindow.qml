import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0

// One place to switch the detection frame on or off for every camera, instead of right-clicking each tile.
// It writes the same two lists the tile's right-click item writes (targetOffCameras for cameras with their own
// connection, targetNvrOnCameras for cameras behind a recorder), so the two always agree.
Window {
    id: win

    width: 460
    height: 560
    minimumWidth: 340
    minimumHeight: 260
    color: "#0f151b"
    title: qsTr("Detection frame per camera")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    // One row per recorder (a header) and one per camera.
    property var rows: []

    function parseList(text) {
        try {
            var l = JSON.parse(text || "[]");
            return Array.isArray(l) ? l : [];
        } catch (e) {
            return [];
        }
    }

    function reload() {
        var out = [];
        var list = [];
        try { list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]"); } catch (e) {}
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            var ip = (rec.ip || "").trim().split(":")[0];
            if (ip === "")
                continue;
            var cams = rec.cameras || [];
            var recName = rec.name || ip;
            if (cams.length <= 2) {
                // A camera with its own connection: one box for the camera.
                out.push({ header: false, standalone: true, key: ip, label: recName, group: ip });
            } else {
                out.push({ header: true, label: recName, group: ip });
                for (var j = 0; j < cams.length; ++j) {
                    var ch = parseInt(cams[j].channelId);
                    out.push({ header: false, standalone: false, key: ip + "#" + ch, group: ip,
                               label: qsTr("Ch. %1  %2").arg(ch).arg(cams[j].customName || cams[j].name || qsTr("Camera %1").arg(ch)) });
                }
            }
        }
        win.rows = out;
    }

    function isOn(row, offText, nvrText) {
        if (row.standalone)
            return win.parseList(offText).indexOf(row.key) < 0;
        return win.parseList(nvrText).indexOf(row.key) >= 0;
    }

    // Switch a set of cameras at once. group "" means every camera.
    function setMany(group, on) {
        var off = win.parseList(generalSettings.targetOffCameras);
        var nvr = win.parseList(generalSettings.targetNvrOnCameras);
        for (var i = 0; i < win.rows.length; ++i) {
            var r = win.rows[i];
            if (r.header || (group !== "" && r.group !== group))
                continue;
            if (r.standalone) {
                var a = off.indexOf(r.key);
                if (on && a >= 0) off.splice(a, 1);
                else if (!on && a < 0) off.push(r.key);
            } else {
                var b = nvr.indexOf(r.key);
                if (on && b < 0) nvr.push(r.key);
                else if (!on && b >= 0) nvr.splice(b, 1);
            }
        }
        generalSettings.targetOffCameras = JSON.stringify(off);
        generalSettings.targetNvrOnCameras = JSON.stringify(nvr);
    }

    function setOne(row, on) {
        var off = win.parseList(generalSettings.targetOffCameras);
        var nvr = win.parseList(generalSettings.targetNvrOnCameras);
        if (row.standalone) {
            var a = off.indexOf(row.key);
            if (on && a >= 0) off.splice(a, 1);
            else if (!on && a < 0) off.push(row.key);
            generalSettings.targetOffCameras = JSON.stringify(off);
        } else {
            var b = nvr.indexOf(row.key);
            if (on && b < 0) nvr.push(row.key);
            else if (!on && b >= 0) nvr.splice(b, 1);
            generalSettings.targetNvrOnCameras = JSON.stringify(nvr);
        }
    }

    onVisibleChanged: {
        if (visible)
            win.reload();
    }

    onClosing: {
        win.destroy();
        if (typeof rootWindow !== "undefined" && rootWindow)
            rootWindow.triggerGcDeferred();
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Text {
            Layout.fillWidth: true
            visible: !generalSettings.showTargetIndicator
            text: qsTr("The detection frame is switched off in the settings, so no camera shows one. Turn it on there first.")
            color: "#e0a040"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            text: qsTr("Tick the cameras that should show a frame and label when they detect something. The detection log keeps every report whatever is ticked here.")
            color: "#8898a6"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Button { text: qsTr("All on"); onClicked: win.setMany("", true) }
            Button { text: qsTr("All off"); onClicked: win.setMany("", false) }
            Item { Layout.fillWidth: true }
        }

        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.rows
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                width: view.width
                height: modelData.header ? 34 : 28

                // Re-read whenever either list changes.
                readonly property bool on: !modelData.header && win.isOn(modelData, generalSettings.targetOffCameras, generalSettings.targetNvrOnCameras)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: modelData.header ? 0 : (modelData.standalone ? 0 : 16)
                    spacing: 8
                    visible: modelData.header

                    Text {
                        text: modelData.label
                        color: "#00f5d4"
                        font { pixelSize: 12; bold: true }
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    Button { text: qsTr("All on"); onClicked: win.setMany(modelData.group, true) }
                    Button { text: qsTr("All off"); onClicked: win.setMany(modelData.group, false) }
                }

                CheckBox {
                    visible: !modelData.header
                    anchors.left: parent.left
                    anchors.leftMargin: modelData.standalone ? 0 : 16
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    checked: parent.on
                    onToggled: win.setOne(modelData, checked)
                }
            }
        }
    }
}
