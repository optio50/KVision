import QtQuick 2.11
import QtQuick.Controls 2.4
import QtQuick.Layouts 1.11
import QtQuick.Window 2.11

// Non-modal, always-on-top window (movable by its title bar) so several cameras
// can be added to a layout in a row without reopening it.
Window {
    id: rootDialog
    flags: Qt.Window | Qt.WindowStaysOnTopHint | Qt.WindowTitleHint | Qt.WindowCloseButtonHint | Qt.WindowSystemMenuHint
    width: 420
    height: Math.min(520, Screen.height * 0.8)
    minimumWidth: 300
    minimumHeight: 240
    color: "#1c242c"
    visible: false

    property int targetIndex: -1
    property var layoutModel: null
    property var expandedIps: ({})
    property var rows: []

    title: qsTr("LNG_00571")

    function cameraLabel(cam) {
        if (!cam)
            return "";
        if (cam.customName && String(cam.customName).length > 0)
            return String(cam.customName);
        if (cam.name && String(cam.name).length > 0)
            return String(cam.name);
        return qsTr("LNG_00574").arg(cam.channelId);
    }

    // "ip/channel" -> number of visible cells in the layout showing that camera
    function usedCameras() {
        var used = {};
        if (!layoutModel)
            return used;
        for (var i = 0; i < layoutModel.count; ++i) {
            var vp = layoutModel.get(i);
            // ViewportsLayoutItem.Visible == 0, Hidden (covered by a merged cell) == 1
            if (!vp || vp.visible !== 0)
                continue;
            var u = String(vp.url);
            var at = u.indexOf("hikvision://");
            if (at === -1)
                continue;
            var content = u.substring(at + 12);
            var slash = content.indexOf("/");
            if (slash === -1)
                continue;
            var ip = content.substring(0, slash).split("@").pop().split(":")[0];
            var ch = parseInt(content.substring(slash + 1)) || 1;
            var key = ip + "/" + ch;
            used[key] = (used[key] || 0) + 1;
        }
        return used;
    }

    function rebuildRows() {
        var next = [];
        var used = usedCameras();
        var savedY = (typeof rowList !== "undefined") ? rowList.contentY : 0;
        var recorders = [];
        try {
            var jsonStr = (typeof rootWindow !== "undefined" && rootWindow) ? rootWindow.hikvisionRecordersJson : "";
            recorders = jsonStr ? JSON.parse(jsonStr) : [];
        } catch (e) {
            recorders = [];
        }
        if (!recorders)
            recorders = [];

        for (var i = 0; i < recorders.length; ++i) {
            var rec = recorders[i];
            if (!rec)
                continue;
            var cams = rec.cameras || [];
            var single = cams.length <= 1;
            var ip = rec.ip || "";
            var expanded = !!rootDialog.expandedIps[ip];
            var addedCount = 0;
            for (var k = 0; k < cams.length; ++k) {
                if (used[ip + "/" + cams[k].channelId])
                    addedCount++;
            }
            next.push({
                kind: "recorder",
                ip: ip,
                name: rec.name && String(rec.name).length > 0 ? String(rec.name) : ip,
                cameraCount: cams.length,
                expandable: cams.length > 1,
                expanded: expanded,
                channelId: cams.length === 1 ? cams[0].channelId : 0,
                cameraName: cams.length === 1 ? rootDialog.cameraLabel(cams[0]) : "",
                addedCount: addedCount,
                added: cams.length === 1 && !!used[ip + "/" + cams[0].channelId]
            });
            if (cams.length > 1 && expanded) {
                for (var j = 0; j < cams.length; ++j) {
                    next.push({
                        kind: "camera",
                        ip: ip,
                        name: rootDialog.cameraLabel(cams[j]),
                        cameraCount: 0,
                        expandable: false,
                        expanded: false,
                        channelId: cams[j].channelId,
                        cameraName: "",
                        addedCount: 0,
                        added: !!used[ip + "/" + cams[j].channelId]
                    });
                }
            }
        }
        rootDialog.rows = next;
        if (typeof rowList !== "undefined")
            rowList.contentY = savedY;
    }

    // Refresh the added markers when cameras are added to / removed from the layout
    Timer {
        id: refreshTimer
        interval: 50
        onTriggered: rootDialog.rebuildRows()
    }

    Connections {
        target: rootDialog.layoutModel
        ignoreUnknownSignals: true
        function onDataChanged() {
            if (rootDialog.visible)
                refreshTimer.restart();
        }
    }

    function toggleExpanded(ip) {
        var next = Object.assign({}, rootDialog.expandedIps);
        next[ip] = !next[ip];
        rootDialog.expandedIps = next;
        rebuildRows();
    }

    // Index of the next empty, visible (not merged-away) cell after "from", or -1
    function nextEmptyCell(from) {
        if (!layoutModel)
            return -1;
        for (var i = from + 1; i < layoutModel.count; ++i) {
            var vp = layoutModel.get(i);
            // ViewportsLayoutItem.Visible == 0, Hidden (covered by a merged cell) == 1
            if (vp && vp.visible === 0 && String(vp.url) === "")
                return i;
        }
        return -1;
    }

    function assignCamera(ip, channelId) {
        if (!layoutModel || targetIndex < 0 || targetIndex >= layoutModel.count)
            return;
        var vp = layoutModel.get(targetIndex);
        if (!vp)
            return;
        var url = "hikvision://" + ip + "/" + channelId;
        vp.url = url;
        vp.secondaryUrl = url;
        vp.streamMode = 0;
        // Stay open and move on to the next empty cell so several cameras can be added quickly
        var next = nextEmptyCell(targetIndex);
        if (next >= 0)
            targetIndex = next;
        else
            rootDialog.close();
    }

    // Show (or re-show) the window, keeping it on top of the main window
    function open() {
        if (!visible) {
            var host = (typeof rootWindow !== "undefined" && rootWindow) ? rootWindow : null;
            if (host) {
                x = host.x + (host.width - width) / 2;
                y = host.y + (host.height - height) / 2;
            }
        }
        show();
        raise();
        requestActivate();
    }

    onVisibleChanged: {
        if (visible)
            rebuildRows();
    }

    Shortcut {
        sequence: "Escape"
        enabled: rootDialog.visible
        onActivated: rootDialog.close()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: rootDialog.targetIndex >= 0 ? qsTr("Adding to cell %1").arg(rootDialog.targetIndex + 1) : ""
            color: "#00f5d4"
            font.bold: true
            font.pixelSize: 12
            elide: Text.ElideRight
        }

        Item {
            id: listArea
            Layout.fillWidth: true
            Layout.fillHeight: true

            Text {
                anchors.centerIn: parent
                width: parent.width
                visible: rootDialog.rows.length === 0
                text: qsTr("LNG_00573")
                color: "#8898a6"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            ListView {
                id: rowList
                anchors.fill: parent
                visible: rootDialog.rows.length > 0
                clip: true
                model: rootDialog.rows
                spacing: 4
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    width: rowList.width
                    height: 36
                    radius: 4
                    color: modelData.cameraCount === 0 && modelData.kind === "recorder"
                           ? "transparent"
                           : (rowMouse.containsMouse ? "#2a3540" : "transparent")
                    border.color: modelData.cameraCount === 0 && modelData.kind === "recorder"
                           ? "transparent"
                           : (rowMouse.containsMouse ? "#00f5d4" : "transparent")
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: modelData.kind === "camera" ? 28 : 8
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            visible: modelData.expandable
                            text: modelData.expanded ? "▾" : "▸"
                            color: "#00f5d4"
                            font.pixelSize: 12
                            font.bold: true
                            Layout.preferredWidth: 14
                        }

                        Text {
                            text: modelData.name
                            color: modelData.cameraCount === 0 && modelData.kind === "recorder" ? "#555555" : (modelData.added ? "#8898a6" : "white")
                            font.pixelSize: 12
                            font.bold: modelData.kind === "recorder"
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Text {
                            visible: modelData.kind === "recorder" && modelData.cameraCount > 1
                            text: modelData.addedCount + "/" + modelData.cameraCount
                            color: modelData.addedCount === modelData.cameraCount ? "#00ff66" : (modelData.addedCount > 0 ? "#ff7a00" : "#8898a6")
                            font.pixelSize: 10
                            font.bold: modelData.addedCount > 0
                        }

                        Text {
                            visible: modelData.kind === "recorder" && modelData.cameraCount === 1 && modelData.cameraName.length > 0
                            text: modelData.cameraName
                            color: "#8898a6"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            Layout.maximumWidth: 160
                        }

                        Text {
                            // Camera is already in the current layout
                            visible: modelData.added
                            text: "\u2713"
                            color: "#00ff66"
                            font.pixelSize: 14
                            font.bold: true
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: modelData.cameraCount > 0 || modelData.kind === "camera"
                        cursorShape: (modelData.cameraCount > 0 || modelData.kind === "camera") ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (modelData.kind === "recorder" && modelData.cameraCount === 0)
                                return;
                            if (modelData.expandable)
                                rootDialog.toggleExpanded(modelData.ip);
                            else
                                rootDialog.assignCamera(modelData.ip, modelData.channelId);
                        }
                    }
                }

                ScrollIndicator.vertical: ScrollIndicator {}
            }
        }

        Button {
            id: closeBtn
            text: qsTr("LNG_00575")
            Layout.alignment: Qt.AlignRight
            Layout.preferredWidth: Math.max(80, closeBtn.implicitWidth + 24)
            Layout.preferredHeight: 30

            contentItem: Text {
                text: closeBtn.text
                font.bold: true
                color: closeBtn.pressed ? "#8898a6" : "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: closeBtn.pressed ? "#2a3540" : (closeBtn.hovered ? "#3a4550" : "#222c36")
                radius: 4
                border.color: "#2a3540"
            }
            onClicked: rootDialog.close()
        }
    }
}
