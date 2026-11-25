import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0

// Read-only list of every saved camera's own address, and whether KVision reaches it
// directly or through an NVR. An NVR channel's address is the one the recorder reports.
// Rows are ordered by that address. A missing address stays at the bottom until it arrives.
Window {
    id: win

    width: 760
    height: 560
    minimumWidth: 620
    minimumHeight: 280
    color: "#0f151b"
    title: qsTr("Camera addresses")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    property var rows: []
    readonly property int addressW: 160
    readonly property int connectW: 220

    function channelOf(cam, fallback) {
        var c = parseInt(cam && (cam.channelId !== undefined ? cam.channelId : cam.channel));
        return isNaN(c) ? fallback : c;
    }

    function hostOf(url) {
        var m = String(url || "").match(/^[a-z][a-z0-9+.-]*:\/\/(?:[^@/?#]+@)?([^\/:?#]+)/i);
        return m ? m[1] : "";
    }

    function genericName(name) {
        return /^camera( \d+)?$/i.test((name || "").trim()) || /^ip\s*camera( \d+)?$/i.test((name || "").trim());
    }

    // Four numeric octets, or null when the row has no address yet.
    function addressKey(ip) {
        var parts = String(ip || "").trim().split(".");
        if (parts.length !== 4)
            return null;
        var nums = [];
        for (var i = 0; i < 4; ++i) {
            if (!/^\d{1,3}$/.test(parts[i]))
                return null;
            var n = parseInt(parts[i], 10);
            if (n > 255)
                return null;
            nums.push(n);
        }
        return nums;
    }

    function compareByAddress(a, b) {
        var ak = win.addressKey(a && a.ip);
        var bk = win.addressKey(b && b.ip);
        if (!ak || !bk) {
            if (ak !== bk)
                return ak ? -1 : 1;
            var blank = Utils.compareText(a && a.name, b && b.name);
            if (blank !== 0)
                return blank;
            return (parseInt(a && a.channel) || 0) - (parseInt(b && b.channel) || 0);
        }
        for (var i = 0; i < 4; ++i) {
            if (ak[i] !== bk[i])
                return ak[i] - bk[i];
        }
        var ch = (parseInt(a && a.channel) || 0) - (parseInt(b && b.channel) || 0);
        if (ch !== 0)
            return ch;
        return Utils.compareText(a && a.name, b && b.name);
    }

    function reload() {
        var list = [];
        try { list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]"); } catch (e) { list = []; }
        var rows = [];
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            var ip = String(rec.ip || "").trim().split(":")[0];
            if (ip === "" && rec.streamUrl)
                ip = win.hostOf(rec.streamUrl);
            if (ip === "")
                continue;
            var recName = String(rec.name || "").trim() || ip;
            var cams = rec.cameras || [];
            var own = Utils.isStandaloneRecorder(rec);
            var httpPort = parseInt(rec.httpPort) || 80;
            if (!own)
                HikvisionManager.prefetchProxyChannels(ip, httpPort, rec.username || "", rec.password || "");
            if (cams.length === 0)
                cams = [{ channelId: 1, name: "" }];
            for (var j = 0; j < cams.length; ++j) {
                var cam = cams[j];
                var ch = win.channelOf(cam, j + 1);
                var camName = String(cam.customName || cam.name || "").trim();
                var label = recName;
                if (cams.length > 1) {
                    if (camName !== "" && !win.genericName(camName))
                        label = recName + " — " + camName;
                    else
                        label = recName + " ch " + ch;
                } else if (camName !== "" && !win.genericName(camName) && camName.toLowerCase() !== recName.toLowerCase()) {
                    label = camName;
                }
                var address = ip;
                var pending = false;
                if (!own) {
                    var proxied = HikvisionManager.proxyCameraIfCached(ip, ch);
                    var deviceIp = proxied && proxied.ip ? String(proxied.ip).trim() : "";
                    if (deviceIp !== "")
                        address = deviceIp;
                    else if (HikvisionManager.proxyListKnown(ip))
                        address = "";
                    else if (HikvisionManager.proxyFetchPending(ip))
                        pending = true;
                    else
                        address = "";
                }
                rows.push({
                    name: label,
                    ip: address,
                    pending: pending,
                    standalone: own,
                    channel: own ? 0 : ch,
                    connection: own ? qsTr("Standalone")
                                    : qsTr("NVR — %1 ch %2").arg(recName).arg(ch)
                });
            }
        }
        rows.sort(win.compareByAddress);
        win.rows = rows;
    }

    onVisibleChanged: {
        if (visible)
            win.reload();
    }

    onClosing: win.destroy()

    Connections {
        target: rootWindow
        function onHikvisionRecordersJsonChanged() { win.reload(); }
    }

    Connections {
        target: HikvisionManager
        function onProxyChannelsReady(nvrIp, ok) {
            win.reload();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: qsTr("Each camera's own address. Standalone means KVision talks to that camera directly. NVR means the camera is connected through a recorder, and the address is the one that recorder reports for the channel.")
            color: "#8898a6"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Row {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 14
            spacing: 12
            Text {
                width: parent.width - win.addressW - win.connectW - 24
                text: qsTr("Camera")
                color: "#00f5d4"
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                width: win.addressW
                text: qsTr("Address")
                color: "#00f5d4"
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                width: win.connectW
                text: qsTr("Connection")
                color: "#00f5d4"
                font.pixelSize: 12
                font.bold: true
            }
        }

        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.rows
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                width: view.width
                height: 32
                color: index % 2 === 0 ? "#1a2632" : "#10161c"

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 14
                    spacing: 12

                    Text {
                        width: parent.width - win.addressW - win.connectW - 24
                        height: parent.height
                        text: modelData.name
                        color: "white"
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Text {
                        width: win.addressW
                        height: parent.height
                        text: modelData.pending ? qsTr("reading…") : (modelData.ip !== "" ? modelData.ip : qsTr("—"))
                        color: modelData.ip !== "" ? "#d5dde4" : "#8898a6"
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Text {
                        width: win.connectW
                        height: parent.height
                        text: modelData.connection
                        color: modelData.standalone ? "#9ad7c8" : "#d7c49a"
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
