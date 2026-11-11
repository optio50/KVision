import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0

// A small window that shows the newest entries of the detection log (logs/Detection.log), ten at a
// time, with a button to load older ones. Opened from a tile's right-click menu.
Window {
    id: logWin

    width: 760
    height: 420
    minimumWidth: 520
    minimumHeight: 240
    color: "#0f151b"
    title: qsTr("Detection events")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    // The address of the camera the window was opened from, and its name for the checkbox text.
    property string cameraIp: ""
    property string cameraName: ""
    readonly property int pageSize: 10
    readonly property int leadInSeconds: 10 // playback starts this long before the logged moment

    property var entries: []
    property bool more: false

    function load(reset) {
        var skip = reset ? 0 : logWin.entries.length;
        var r = HikvisionEvents.readDetections(skip, logWin.pageSize, Context.configDirPath(),
                                               onlyThisCamera.checked ? logWin.cameraIp : "");
        var list = reset ? [] : logWin.entries.slice();
        for (var i = 0; i < r.entries.length; ++i)
            list.push(r.entries[i]);
        logWin.entries = list;
        logWin.more = r.more;
    }

    // Entries written before the recorder was logged cannot be opened in playback.
    function canPlay(entry) {
        return entry.recorderIp !== "" && entry.channel > 0 && entry.epochMs > 0;
    }

    function playEntry(entry) {
        if (!logWin.canPlay(entry))
            return;
        if (typeof rootWindow === "undefined" || !rootWindow)
            return;
        if (!rootWindow.openPlaybackAt(entry.recorderIp, entry.channel, entry.epochMs - logWin.leadInSeconds * 1000))
            logWin.notice = qsTr("This camera's recorder is not in the saved list");
        else
            logWin.notice = "";
    }

    property string notice: ""

    function showPicture(entry) {
        if (entry.picture === "")
            return;
        var w = pictureViewer.createObject(null, { "pictures": (entry.pictures && entry.pictures.length > 0) ? entry.pictures : [entry.picture],
                                                    "caption": entry.time + "   " + entry.target + "   " + entry.kind + "   " + entry.camera });
        if (w)
            w.show();
    }

    Component {
        id: pictureViewer
        Window {
            id: pv
            // One picture, or several (a tracking line keeps snapshots a second apart): the buttons step through them.
            property var pictures: []
            property int shown: 0
            property string caption: ""
            width: 960
            height: 600
            minimumWidth: 320
            minimumHeight: 240
            color: "#0f151b"
            title: qsTr("Event picture")
            flags: Qt.Window | Qt.WindowStaysOnTopHint
            onClosing: pv.destroy()

            Text {
                id: cap
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: stepRow.left
                anchors.margins: 8
                text: pv.caption
                color: "#eeeeee"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Row {
                id: stepRow
                visible: pv.pictures.length > 1
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6
                spacing: 6
                Button { text: "\u2039"; enabled: pv.shown > 0; onClicked: pv.shown-- }
                Text { text: (pv.shown + 1) + " / " + pv.pictures.length; color: "#cccccc"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                Button { text: "\u203a"; enabled: pv.shown < pv.pictures.length - 1; onClicked: pv.shown++ }
            }
            Image {
                anchors.top: cap.bottom
                anchors.topMargin: 6
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                source: pv.pictures.length > 0 ? "file://" + pv.pictures[pv.shown] : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }
        }
    }

    function targetColor(target) {
        var t = String(target).toLowerCase();
        return t === "human" ? "#ff5a36" : (t === "vehicle" ? "#2d8cff" : "#2ecc71");
    }

    onVisibleChanged: {
        if (visible)
            load(true);
    }

    onClosing: {
        logWin.destroy();
        if (typeof rootWindow !== "undefined" && rootWindow) {
            rootWindow.triggerGcDeferred();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            CheckBox {
                id: onlyThisCamera
                visible: logWin.cameraIp !== ""
                checked: logWin.cameraIp !== ""
                text: qsTr("Only this camera") + (logWin.cameraName !== "" ? " (" + logWin.cameraName + ")" : "")
                onToggled: logWin.load(true)
                contentItem: Text {
                    leftPadding: onlyThisCamera.indicator.width + 6
                    text: onlyThisCamera.text
                    color: "#eeeeee"
                    font.pixelSize: 12
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Item { Layout.fillWidth: true }

            Button {
                text: qsTr("Refresh")
                onClicked: logWin.load(true)
            }
        }

        // Column headings
        Rectangle {
            Layout.fillWidth: true
            height: 26
            color: "#1c242c"
            radius: 4

            Row {
                anchors.fill: parent
                anchors.leftMargin: 8
                Text { width: 150; height: parent.height; text: qsTr("Time"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                Text { width: 80; height: parent.height; text: qsTr("Target"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                Text { width: 120; height: parent.height; text: qsTr("Type"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                Text { width: parent.width - 350 - 100 - 80; height: parent.height; text: qsTr("Camera"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
                Text { width: 100; height: parent.height; text: qsTr("Address"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                Text { width: 40; height: parent.height; text: qsTr("Picture"); color: "#00f5d4"; font.bold: true; font.pixelSize: 11; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter }
                Text { width: 40; height: parent.height; text: qsTr("Play"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter }
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: logWin.entries
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                id: row
                width: list.width
                height: 26
                color: rowArea.containsMouse && logWin.canPlay(modelData) ? "#22303a" : (index % 2 === 0 ? "#141b22" : "transparent")
                readonly property bool playable: logWin.canPlay(modelData)

                // Double-click anywhere on the row opens playback at that moment.
                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    onDoubleClicked: logWin.playEntry(modelData)
                    ToolTip.visible: containsMouse && row.playable
                    ToolTip.delay: 800
                    ToolTip.text: qsTr("Double-click to play the recording %1 seconds before this moment").arg(logWin.leadInSeconds)
                }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    Text {
                        width: 150; height: parent.height
                        text: modelData.time !== "" ? modelData.time : ""
                        color: "#eeeeee"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter
                        ToolTip.visible: tipArea.containsMouse && modelData.received !== ""
                        ToolTip.text: qsTr("Read by KVision at %1, later than the camera made it").arg(modelData.received)
                        MouseArea { id: tipArea; anchors.fill: parent; hoverEnabled: true }
                    }
                    Text {
                        width: 80; height: parent.height
                        text: modelData.target
                        color: logWin.targetColor(modelData.target); font.pixelSize: 12; font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                    Text {
                        width: 120; height: parent.height
                        text: modelData.kind !== "" ? modelData.kind : "\u2013"
                        color: modelData.kind !== "" ? "#eeeeee" : "#667788"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter
                    }
                    Text {
                        width: parent.width - 350 - 100 - 80; height: parent.height
                        text: modelData.camera + (modelData.received !== "" ? "   (late)" : "")
                        color: modelData.received !== "" ? "#aa9966" : "#eeeeee"; font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                    }
                    Text {
                        width: 100; height: parent.height
                        text: modelData.ip
                        color: "#8899aa"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter
                    }
                    Item {
                        width: 40; height: parent.height
                        Rectangle {
                            anchors.centerIn: parent
                            width: 26; height: 20; radius: 4
                            visible: modelData.picture !== ""
                            color: picArea.containsMouse ? "#00f5d4" : "#2a3540"
                            Rectangle {
                                anchors.centerIn: parent
                                width: 14; height: 10; radius: 2
                                color: "transparent"
                                border.width: 1
                                border.color: picArea.containsMouse ? "#0f151b" : "#00f5d4"
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 4; height: 4; radius: 2
                                    color: picArea.containsMouse ? "#0f151b" : "#00f5d4"
                                }
                            }
                            MouseArea {
                                id: picArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: logWin.showPicture(modelData)
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 500
                                ToolTip.text: qsTr("Show the picture the camera sent with this event")
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: modelData.picture === ""
                            text: "\u2013"
                            color: "#445566"; font.pixelSize: 12
                            ToolTip.visible: noPicArea.containsMouse
                            ToolTip.text: qsTr("No picture kept for this entry (only line and area events bring one, and only the newest ones of each camera are kept, see the setting in the sidebar)")
                            MouseArea { id: noPicArea; anchors.fill: parent; hoverEnabled: true }
                        }
                    }
                    Item {
                        width: 40; height: parent.height
                        Rectangle {
                            anchors.centerIn: parent
                            width: 26; height: 20; radius: 4
                            visible: row.playable
                            color: playArea.containsMouse ? "#00f5d4" : "#2a3540"
                            Text {
                                anchors.centerIn: parent
                                text: "\u25B6"
                                font.pixelSize: 10
                                color: playArea.containsMouse ? "#0f151b" : "#00f5d4"
                            }
                            MouseArea {
                                id: playArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: logWin.playEntry(modelData)
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 500
                                ToolTip.text: qsTr("Play the recording %1 seconds before this moment").arg(logWin.leadInSeconds)
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !row.playable
                            text: "\u2013"
                            color: "#445566"; font.pixelSize: 12
                            ToolTip.visible: noPlayArea.containsMouse
                            ToolTip.text: qsTr("Logged before playback links were recorded")
                            MouseArea { id: noPlayArea; anchors.fill: parent; hoverEnabled: true }
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: logWin.entries.length === 0
                text: qsTr("No detections logged yet")
                color: "#8899aa"
                font.pixelSize: 13
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Text {
                text: qsTr("%1 shown").arg(logWin.entries.length)
                color: "#8899aa"
                font.pixelSize: 12
            }

            Text {
                visible: logWin.notice !== ""
                text: logWin.notice
                color: "#e0a040"
                font.pixelSize: 12
            }

            Item { Layout.fillWidth: true }

            Button {
                visible: logWin.more
                text: qsTr("Load %1 more").arg(logWin.pageSize)
                onClicked: logWin.load(false)
            }
        }
    }
}
