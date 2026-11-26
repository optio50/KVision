import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Hikvision 1.0

// Tick the cameras whose live Hikvision audio should go through the local AAC repair.
// An empty list leaves every picture on the direct path.
Window {
    id: win

    width: 640
    height: 560
    minimumWidth: 420
    minimumHeight: 260
    color: "#0f151b"
    title: qsTr("Repair Hikvision live audio")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    property var rows: []
    property bool showingSummary: false
    property var summary: []
    readonly property int colW: 120

    function parseList(text) {
        try {
            var l = JSON.parse(text || "[]");
            return Array.isArray(l) ? l : [];
        } catch (e) {
            return [];
        }
    }

    function listed(key) {
        return win.parseList(generalSettings.repairAacCameras).indexOf(key) >= 0;
    }

    function byName(a, b) {
        var an = (a.name || "").toLowerCase();
        var bn = (b.name || "").toLowerCase();
        if (an < bn) return -1;
        if (an > bn) return 1;
        return 0;
    }

    function channelOf(cam, fallback) {
        var c = parseInt(cam && cam.channelId);
        return isNaN(c) ? fallback : c;
    }

    function camLabel(cam, fallback) {
        if (!cam)
            return fallback;
        var name = (cam.customName || cam.name || "").trim();
        return name !== "" ? name : fallback;
    }

    function reload() {
        var singles = [];
        var duals = [];
        var nvrs = [];
        var list = [];
        try { list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]"); } catch (e) {}
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            if (rec.streamUrl)
                continue; // a saved RTSP or HTTP address is not a Hikvision camera
            var ip = (rec.ip || "").trim().split(":")[0];
            if (ip === "")
                continue;
            var cams = rec.cameras || [];
            var item = { name: rec.name || ip, ip: ip, cams: cams, username: rec.username || "",
                         password: rec.password || "", rtspPort: rec.rtspPort || 554 };
            if (cams.length > 2)
                nvrs.push(item);
            else if (cams.length === 2)
                duals.push(item);
            else
                singles.push(item);
        }
        var own = singles.concat(duals);
        own.sort(win.byName);
        nvrs.sort(win.byName);

        var out = [];
        for (var s = 0; s < own.length; ++s) {
            var dev = own[s];
            if ((dev.cams || []).length === 2) {
                out.push({ kind: "dual", label: dev.name, group: dev.ip });
                var lenses = Utils.sortByChannel(dev.cams);
                for (var lens = 0; lens < lenses.length; ++lens) {
                    var lc = win.channelOf(lenses[lens], lens + 1);
                    out.push({ kind: "lens", key: dev.ip + "#" + lc, group: dev.ip,
                               label: win.camLabel(lenses[lens], qsTr("Lens %1").arg(lens + 1)),
                               url: win.liveSubUrl(dev, lc) });
                }
            } else {
                var ch = win.channelOf(dev.cams[0], 1);
                out.push({ kind: "camera", key: dev.ip + "#" + ch, group: dev.ip, label: dev.name,
                           url: win.liveSubUrl(dev, ch) });
            }
        }
        for (var n = 0; n < nvrs.length; ++n) {
            var nvr = nvrs[n];
            out.push({ kind: "nvr", label: nvr.name, group: nvr.ip });
            var channels = Utils.sortByChannel(nvr.cams);
            for (var j = 0; j < channels.length; ++j) {
                var nc = win.channelOf(channels[j], j + 1);
                out.push({ kind: "channel", key: nvr.ip + "#" + nc, group: nvr.ip,
                           label: qsTr("Ch. %1  %2").arg(nc).arg(win.camLabel(channels[j], qsTr("Camera %1").arg(nc))),
                           url: win.liveSubUrl(nvr, nc) });
            }
        }
        win.rows = out;
    }

    function setOne(key, on) {
        var l = win.parseList(generalSettings.repairAacCameras);
        var at = l.indexOf(key);
        if (on && at < 0)
            l.push(key);
        else if (!on && at >= 0)
            l.splice(at, 1);
        else
            return;
        generalSettings.repairAacCameras = JSON.stringify(l);
    }

    function liveSubUrl(dev, channel) {
        var creds = "";
        if (dev.username)
            creds = encodeURIComponent(dev.username) + (dev.password ? (":" + encodeURIComponent(dev.password)) : "") + "@";
        return "rtsp://" + creds + dev.ip + ":" + (dev.rtspPort || 554) + "/Streaming/Channels/" + (channel * 100 + 2);
    }

    function rank(state) {
        if (state === "problem") return 0;
        if (state === "error") return 1;
        if (state === "ok") return 2;
        return 3;
    }

    function startCheck() {
        var jobs = [];
        for (var i = 0; i < win.rows.length; ++i) {
            var row = win.rows[i];
            if (!row.key || !row.url)
                continue;
            jobs.push({ key: row.key, name: row.label, url: row.url });
        }
        win.summary = [];
        win.showingSummary = false;
        RtspAudioCompat.startAudioCheck(jobs);
    }

    function addResult(row) {
        if (row.needsRepair)
            win.setOne(row.key, true);
        var list = win.summary.slice();
        var at = list.length;
        var name = (row.name || "").toLowerCase();
        for (var i = 0; i < list.length; ++i) {
            var ahead = win.rank(row.state) < win.rank(list[i].state);
            var same = win.rank(row.state) === win.rank(list[i].state)
                    && name < (list[i].name || "").toLowerCase();
            if (ahead || same) {
                at = i;
                break;
            }
        }
        list.splice(at, 0, row);
        win.summary = list;
    }

    function summaryCount(state) {
        var n = 0;
        for (var i = 0; i < win.summary.length; ++i) {
            if (win.summary[i].state === state)
                n++;
        }
        return n;
    }

    function summaryLine() {
        var parts = [];
        var repair = win.summaryCount("problem");
        var fine = win.summaryCount("ok");
        var silent = win.summaryCount("off");
        var missed = win.summaryCount("error");
        parts.push(qsTr("%1 need repair").arg(repair));
        parts.push(qsTr("%1 are fine").arg(fine));
        if (silent > 0)
            parts.push(qsTr("%1 have no audio").arg(silent));
        if (missed > 0)
            parts.push(qsTr("%1 could not be read").arg(missed));
        return parts.join(", ");
    }

    function resultText(row) {
        if (row.key && win.listed(row.key))
            return qsTr("repair enabled");
        if (row.state === "problem") return qsTr("needs repair");
        if (row.state === "ok") return qsTr("ok");
        if (row.state === "error") return qsTr("could not read");
        return qsTr("no audio");
    }

    function statusColor(row) {
        if (row.key && win.listed(row.key))
            return "#3dbb78";
        return win.resultColor(row.state);
    }

    function resultColor(state) {
        if (state === "problem") return "#f2574f";
        if (state === "ok") return "#3dbb78";
        return "#8899aa";
    }

    function clearAll() {
        if (win.parseList(generalSettings.repairAacCameras).length === 0)
            return;
        generalSettings.repairAacCameras = "[]";
    }

    onVisibleChanged: {
        if (visible)
            win.reload();
    }

    onClosing: {
        RtspAudioCompat.cancelAudioCheck();
        win.destroy();
    }

    Connections {
        target: RtspAudioCompat
        onAudioChecked: win.addResult(row)
        onAudioCheckFinished: win.showingSummary = true
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: qsTr("Tick a camera whose live sound was dropped. Only a ticked camera goes through the repair on this computer. Every other camera stays as it is. The cameras and their recordings are not changed.")
            color: "#8898a6"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button {
                text: qsTr("Clear")
                enabled: !RtspAudioCompat.audioCheckRunning && !win.showingSummary
                onClicked: win.clearAll()
            }
            Button {
                text: RtspAudioCompat.audioCheckRunning
                      ? qsTr("Checking %1 of %2").arg(RtspAudioCompat.audioCheckDone).arg(RtspAudioCompat.audioCheckTotal)
                      : qsTr("Find broken audio")
                enabled: !RtspAudioCompat.audioCheckRunning
                hoverEnabled: true
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.timeout: 8000
                ToolTip.text: qsTr("Read each camera's live audio description and tick the ones this repair can rewrite. A correct description, and a camera with no audio, stay unticked.")
                onClicked: win.startCheck()
            }
            Button {
                visible: win.showingSummary
                text: qsTr("Back to the list")
                onClicked: win.showingSummary = false
            }
            Item { Layout.fillWidth: true }
        }

        Text {
            Layout.fillWidth: true
            visible: win.showingSummary
            text: win.summaryLine()
            color: "#eeeeee"
            font.pixelSize: 13
            font.bold: true
            wrapMode: Text.Wrap
        }

        Row {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.rightMargin: 14
            spacing: 0
            Item { width: parent.width - win.colW; height: 1 }
            Text {
                width: win.colW
                text: qsTr("Repair audio")
                color: "#00f5d4"
                font.pixelSize: 12
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
            }
        }

        ListView {
            id: summaryView
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.showingSummary
            clip: true
            model: win.summary
            spacing: 4
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                width: summaryView.width
                height: 32
                radius: 4
                color: "#141b22"
                border.width: 1
                border.color: modelData.state === "problem" ? "#7a2a26" : (modelData.state === "ok" ? "#1f5a38" : "#2a3540")

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 14
                    spacing: 8
                    Rectangle {
                        width: 10
                        height: 10
                        radius: 5
                        anchors.verticalCenter: parent.verticalCenter
                        color: win.resultColor(modelData.state)
                    }
                    Text {
                        width: Math.max(40, parent.width - 10 - 52 - 120 - win.colW - 32)
                        height: parent.height
                        text: modelData.name
                        color: "#eeeeee"
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Text {
                        width: 52
                        height: parent.height
                        text: modelData.hasAudio ? (modelData.codec || qsTr("audio")) : ""
                        color: win.resultColor(modelData.state)
                        font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Text {
                        width: 120
                        height: parent.height
                        text: win.resultText(modelData)
                        color: win.statusColor(modelData)
                        font.pixelSize: 12
                        font.bold: modelData.state === "problem" && !win.listed(modelData.key)
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Item {
                        width: win.colW
                        height: parent.height
                        CheckBox {
                            anchors.centerIn: parent
                            checked: win.listed(modelData.key)
                            onToggled: win.setOne(modelData.key, checked)
                        }
                    }
                }
            }
        }

        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !win.showingSummary
            clip: true
            model: win.rows
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                width: view.width
                height: modelData.kind === "nvr" ? 36 : (modelData.kind === "dual" ? 26 : 30)

                Rectangle {
                    anchors.fill: parent
                    color: (modelData.kind === "nvr" || modelData.kind === "dual") ? "#162028"
                           : (index % 2 === 0 ? "#1a2632" : "#10161c")
                }

                Row {
                    anchors.fill: parent
                    anchors.rightMargin: 14
                    anchors.leftMargin: modelData.kind === "lens" || modelData.kind === "channel" ? 18 : 4
                    spacing: 0
                    visible: modelData.kind === "dual" || modelData.kind === "nvr"

                    Text {
                        width: parent.width - win.colW
                        height: parent.height
                        text: modelData.label
                        color: modelData.kind === "nvr" ? "#00f5d4" : "#c5d0d8"
                        font.pixelSize: modelData.kind === "nvr" ? 13 : 12
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Item { width: win.colW; height: 1 }
                }

                Row {
                    anchors.fill: parent
                    anchors.rightMargin: 14
                    anchors.leftMargin: modelData.kind === "camera" ? 4 : 18
                    spacing: 0
                    visible: modelData.kind === "camera" || modelData.kind === "lens" || modelData.kind === "channel"

                    Text {
                        width: parent.width - win.colW
                        height: parent.height
                        text: modelData.label
                        color: "#eeeeee"
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    Item {
                        width: win.colW
                        height: parent.height
                        CheckBox {
                            anchors.centerIn: parent
                            checked: win.listed(modelData.key)
                            onToggled: win.setOne(modelData.key, checked)
                        }
                    }
                }
            }
        }
    }
}
