import QtQuick 2.11
import QtQuick.Controls 2.4
import QtQuick.Layouts 1.11
import QtQuick.Window 2.11

Dialog {
    id: rootDialog
    modal: true
    anchors.centerIn: parent
    width: 420
    height: Math.min(Math.max(implicitHeight, 320), Screen.height * 0.8)

    leftPadding: 16
    rightPadding: 16
    topPadding: 12
    bottomPadding: 12

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

    function rebuildRows() {
        var next = [];
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
            next.push({
                kind: "recorder",
                ip: ip,
                name: rec.name && String(rec.name).length > 0 ? String(rec.name) : ip,
                cameraCount: cams.length,
                expandable: cams.length > 1,
                expanded: expanded,
                channelId: cams.length === 1 ? cams[0].channelId : 0,
                cameraName: cams.length === 1 ? rootDialog.cameraLabel(cams[0]) : ""
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
                        cameraName: ""
                    });
                }
            }
        }
        rootDialog.rows = next;
    }

    function toggleExpanded(ip) {
        var next = Object.assign({}, rootDialog.expandedIps);
        next[ip] = !next[ip];
        rootDialog.expandedIps = next;
        rebuildRows();
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
        rootDialog.accept();
    }

    onAboutToShow: rebuildRows()

    background: Rectangle {
        color: "#1c242c"
        border.color: "#2a3540"
        border.width: 1
        radius: 8
    }

    header: Rectangle {
        color: "#0f151b"
        height: 42
        implicitHeight: 42
        radius: 8

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 4
            color: "#0f151b"
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: "#2a3540"
        }

        Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: rootDialog.title
            color: "#00f5d4"
            font.bold: true
            font.pixelSize: 13
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }
    }

    contentItem: Item {
        implicitHeight: 280

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
                        color: modelData.cameraCount === 0 && modelData.kind === "recorder" ? "#555555" : "white"
                        font.pixelSize: 12
                        font.bold: modelData.kind === "recorder"
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Text {
                        visible: modelData.kind === "recorder" && modelData.cameraCount > 1
                        text: String(modelData.cameraCount)
                        color: "#8898a6"
                        font.pixelSize: 10
                    }

                    Text {
                        visible: modelData.kind === "recorder" && modelData.cameraCount === 1 && modelData.cameraName.length > 0
                        text: modelData.cameraName
                        color: "#8898a6"
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        Layout.maximumWidth: 160
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

    footer: Rectangle {
        implicitHeight: 48
        color: "#0f151b"
        border.color: "#2a3540"
        border.width: 1
        radius: 8

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 1
            height: 4
            color: "#0f151b"
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 8

            Item { Layout.fillWidth: true }

            Button {
                id: closeBtn
                text: qsTr("LNG_00019")
                Layout.preferredWidth: 80
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
                onClicked: rootDialog.reject()
            }
        }
    }
}

