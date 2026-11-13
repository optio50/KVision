import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0

// A read only look at each camera's own settings, reached on the camera's own address. Nothing in this window
// can change a camera. A section a camera does not offer is simply not shown.
Window {
    id: win

    width: Math.min(1620, Screen.desktopAvailableWidth - 20)
    height: 720
    minimumWidth: 800
    minimumHeight: 420
    color: "#0f151b"
    title: qsTr("Camera settings (read only)")

    property var cameras: []
    property var sections: []
    property var overview: []
    property string message: ""
    property int overviewDone: 0
    property int overviewTotal: 0
    property bool showOverview: false
    // Column widths of the all-cameras table, shared by the header and the rows so they always line up. The light
    // "triggered by" column (index 6) takes whatever width is left over.
    readonly property var overviewHeads: [qsTr("Camera"), qsTr("Model"), qsTr("Firmware"), qsTr("Audio hours"), qsTr("Audio triggered by"),
                                          qsTr("Light hours"), qsTr("Light triggered by"), qsTr("Motion"), qsTr("Intrusion"), qsTr("Line")]
    readonly property var overviewCols: [220, 170, 70, 250, 200, 120, 300, 55, 65, 45]
    readonly property int overviewMinWidth: 1560

    Component.onCompleted: HikvisionCameraInfo.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName)

    Connections {
        target: HikvisionCameraInfo
        function onCamerasLoaded(list) {
            win.cameras = list;
            if (list.length > 0 && cameraCombo.currentIndex < 0)
                cameraCombo.currentIndex = 0;
        }
        function onCameraRead(ip, secs) {
            win.sections = secs;
            win.message = "";
        }
        function onReadFailed(ip, why) {
            win.sections = [];
            win.message = why;
        }
        function onOverviewProgress(done, total) {
            win.overviewDone = done;
            win.overviewTotal = total;
        }
        function onOverviewRead(rows) {
            win.overview = rows;
            win.overviewTotal = 0;
        }
    }

    function readSelected() {
        var cam = win.cameras[cameraCombo.currentIndex];
        if (!cam)
            return;
        win.sections = [];
        win.message = qsTr("Reading %1...").arg(cam.name);
        HikvisionCameraInfo.readCamera(cam.ip, userField.text, passField.text);
        passField.text = "";
    }

    // The hours as a 24 hour bar for one day: the armed spans are drawn in blue.
    Component {
        id: weekComponent
        Column {
            property var week: []
            spacing: 2
            Repeater {
                model: 7
                delegate: Row {
                    spacing: 6
                    Text {
                        width: 30
                        text: [qsTr("Mon"), qsTr("Tue"), qsTr("Wed"), qsTr("Thu"), qsTr("Fri"), qsTr("Sat"), qsTr("Sun")][index]
                        color: "#8898a6"
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        width: 480
                        height: 12
                        color: "#1c242c"
                        border.color: "#2a3540"
                        Repeater {
                            model: (week[index] || [])
                            delegate: Rectangle {
                                x: modelData.from / 1440 * 480
                                width: Math.max(1, (modelData.to - modelData.from) / 1440 * 480)
                                height: parent.height
                                color: "#2f5bd6"
                            }
                        }
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ComboBox {
                id: cameraCombo
                Layout.fillWidth: true
                model: win.cameras
                textRole: "name"
                enabled: !HikvisionCameraInfo.busy && !win.showOverview
                onActivated: win.readSelected()
                background: Rectangle {
                    implicitHeight: 32
                    color: "#0f151b"
                    border.color: cameraCombo.activeFocus ? "#ff7a00" : "#2a3540"
                    radius: 4
                }
                contentItem: Text {
                    text: cameraCombo.displayText
                    color: "white"
                    font.pixelSize: 11
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    elide: Text.ElideRight
                }
                delegate: ItemDelegate {
                    width: cameraCombo.width
                    height: 30
                    contentItem: Text {
                        text: modelData.name + "  (" + modelData.ip + ")"
                        color: hovered ? "#ff7a00" : "white"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }
                    background: Rectangle { color: hovered ? "#2a3540" : "transparent"; radius: 4 }
                }
                popup: Popup {
                    y: cameraCombo.height + 2
                    width: cameraCombo.width
                    implicitHeight: Math.min(360, contentItem.implicitHeight + 8)
                    padding: 4
                    contentItem: ListView {
                        clip: true
                        implicitHeight: contentHeight
                        model: cameraCombo.popup.visible ? cameraCombo.delegateModel : null
                    }
                    background: Rectangle { color: "#0f151b"; border.color: "#ff7a00"; radius: 6 }
                }
            }

            Button {
                id: readBtn
                text: qsTr("Read")
                enabled: !HikvisionCameraInfo.busy && !win.showOverview && cameraCombo.currentIndex >= 0
                onClicked: win.readSelected()
                contentItem: Text { text: readBtn.text; color: readBtn.enabled ? "white" : "#8898a6"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: !readBtn.enabled ? "#303030" : (readBtn.hovered ? "#ff8c00" : "#ff7a00"); radius: 4 }
            }

            Button {
                id: copyAllBtn
                text: qsTr("Copy table as text")
                visible: win.showOverview
                enabled: win.overview.length > 0
                onClicked: {
                    Clipboard.setText(HikvisionCameraInfo.overviewToText(win.overview));
                    win.message = qsTr("Copied %1 cameras (tab separated, ready for a spreadsheet)").arg(win.overview.length);
                }
                contentItem: Text { text: copyAllBtn.text; color: copyAllBtn.enabled ? "white" : "#8898a6"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: !copyAllBtn.enabled ? "#303030" : (copyAllBtn.hovered ? "#3a4550" : "#2a3540"); border.color: "#00f5d4"; radius: 4 }
            }

            Button {
                id: overviewBtn
                text: win.showOverview ? qsTr("One camera") : qsTr("All cameras")
                enabled: !HikvisionCameraInfo.busy
                onClicked: {
                    win.showOverview = !win.showOverview;
                    if (win.showOverview && win.overview.length === 0)
                        HikvisionCameraInfo.readOverview();
                }
                contentItem: Text { text: overviewBtn.text; color: overviewBtn.enabled ? "white" : "#8898a6"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: !overviewBtn.enabled ? "#303030" : (overviewBtn.hovered ? "#22c55e" : "#16a34a"); radius: 4 }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: !win.showOverview

            TextField {
                id: userField
                text: "admin"
                placeholderText: "admin"
                selectByMouse: true
                Layout.fillWidth: true
                color: "white"
                background: Rectangle { color: "#0f151b"; radius: 4; border.color: userField.activeFocus ? "#ff7a00" : "#2a3540" }
            }
            TextField {
                id: passField
                placeholderText: qsTr("Camera password (only if different from the recorder's)")
                echoMode: TextInput.Password
                selectByMouse: true
                Layout.fillWidth: true
                color: "white"
                background: Rectangle { color: "#0f151b"; radius: 4; border.color: passField.activeFocus ? "#ff7a00" : "#2a3540" }
                onAccepted: win.readSelected()
            }
            Button {
                id: copyBtn
                text: qsTr("Copy as text")
                enabled: win.sections.length > 0
                onClicked: {
                    Clipboard.setText(HikvisionCameraInfo.sectionsToText(win.sections));
                    win.message = qsTr("Copied");
                }
                contentItem: Text { text: copyBtn.text; color: copyBtn.enabled ? "white" : "#8898a6"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: "#1c242c"; border.color: "#2a3540"; radius: 4 }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: win.showOverview && win.overviewTotal > 0 ? qsTr("Reading cameras... %1 of %2").arg(win.overviewDone).arg(win.overviewTotal) : win.message
            color: HikvisionCameraInfo.busy ? "#00f5d4" : "#ff9f43"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        // One camera
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !win.showOverview
            clip: true
            ColumnLayout {
                width: win.width - 48
                spacing: 10
                Repeater {
                    model: win.sections
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: secCol.implicitHeight + 16
                        color: "#1c242c"
                        radius: 6
                        border.color: "#2a3540"
                        ColumnLayout {
                            id: secCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 8
                            spacing: 3
                            Text { text: modelData.title; color: "#00f5d4"; font.bold: true; font.pixelSize: 12 }
                            Repeater {
                                model: modelData.rows
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text { text: modelData.label; color: "#8898a6"; font.pixelSize: 11; Layout.preferredWidth: 170; Layout.alignment: Qt.AlignTop }
                                    Text { text: modelData.value; color: "white"; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap; Layout.alignment: Qt.AlignTop }
                                }
                            }
                            Loader {
                                visible: modelData.week !== undefined
                                active: modelData.week !== undefined
                                sourceComponent: weekComponent
                                onLoaded: item.week = modelData.week
                            }
                        }
                    }
                }
            }
        }

        // All cameras
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.showOverview
            clip: true
            contentWidth: overviewCol.width
            ColumnLayout {
                id: overviewCol
                width: Math.max(win.overviewMinWidth, win.width - 28)
                spacing: 1
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.overviewHeads
                        delegate: Text {
                            text: modelData
                            Layout.preferredWidth: win.overviewCols[index]
                            Layout.fillWidth: index === 6
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 11
                        }
                    }
                }
                Repeater {
                    model: win.overview
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        color: index % 2 === 0 ? "#141a21" : "#1c242c"
                        RowLayout {
                            anchors.fill: parent
                            spacing: 6
                            Text { text: modelData.name; Layout.preferredWidth: win.overviewCols[0]; elide: Text.ElideRight; color: modelData.error !== "" ? "#ff9f43" : "white"; font.pixelSize: 11 }
                            Text { text: modelData.error !== "" ? modelData.error : modelData.model; Layout.preferredWidth: win.overviewCols[1]; elide: Text.ElideRight; color: modelData.error !== "" ? "#ff9f43" : "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.firmware; Layout.preferredWidth: win.overviewCols[2]; elide: Text.ElideRight; color: "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.audio; Layout.preferredWidth: win.overviewCols[3]; elide: Text.ElideRight; color: (modelData.audio !== "-" && modelData.audio.indexOf("all day") !== 0) ? "#ff9f43" : "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.audioFrom; Layout.preferredWidth: win.overviewCols[4]; elide: Text.ElideRight; color: "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.light; Layout.preferredWidth: win.overviewCols[5]; elide: Text.ElideRight; color: (modelData.light !== "-" && modelData.light.indexOf("all day") !== 0) ? "#ff9f43" : "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.lightFrom; Layout.preferredWidth: win.overviewCols[6]; Layout.fillWidth: true; elide: Text.ElideRight; color: "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.motion; Layout.preferredWidth: win.overviewCols[7]; color: "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.intrusion; Layout.preferredWidth: win.overviewCols[8]; color: "#c8d2dc"; font.pixelSize: 11 }
                            Text { text: modelData.line; Layout.preferredWidth: win.overviewCols[9]; color: "#c8d2dc"; font.pixelSize: 11 }
                        }
                    }
                }
                Text {
                    visible: win.overview.length > 0
                    text: qsTr("Orange audio or light hours are not all day: that action only runs inside those hours, whatever the recorder asks for.")
                    color: "#8898a6"
                    font.pixelSize: 10
                    topPadding: 6
                }
            }
        }
    }
}
