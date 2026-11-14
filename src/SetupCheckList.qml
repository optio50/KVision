import QtQuick 2.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Utils 1.0

// The list of check results: one card per camera, the card clicked shows every line the check found.
ListView {
    id: list

    property var results: []
    property string openKey: ""
    property string focusKey: "" // the camera of interest: shaded, and always listed first
    property bool busy: false    // a check is running: the small check-again buttons wait
    signal recheck(string key)   // the small button on a card was pressed: check that one camera again

    clip: true
    model: results
    spacing: 4
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}

    function stateColor(state) {
        return state === "ok" ? "#14a24c" : (state === "problem" ? "#e0241f" : (state === "note" || state === "warning" ? "#e0a040" : (state === "off" ? "#667788" : "#8899aa")));
    }

    function stateMark(state) {
        return state === "ok" ? "\u2713" : (state === "problem" ? "\u2717" : (state === "note" || state === "warning" ? "!" : (state === "off" ? "\u2013" : "?")));
    }

    delegate: Rectangle {
        id: card
        readonly property bool isOpen: list.openKey === modelData.key
        width: list.width
        height: head.height + (isOpen ? body.height + 8 : 0) + 14
        readonly property bool isFocus: list.focusKey !== "" && list.focusKey === modelData.key
        color: isFocus ? "#1c2f44" : "#141b22"
        radius: 4
        border.width: isFocus ? 2 : 1
        border.color: isFocus ? "#4a9eff" : (modelData.problems > 0 ? "#7a2a26" : (modelData.warnings > 0 ? "#5a4a28" : "#1f5a38"))

        MouseArea {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: head.height + 12
            onClicked: list.openKey = card.isOpen ? "" : modelData.key
        }

        Row {
            id: head
            x: 10
            y: 6
            spacing: 10
            height: 24

            Rectangle {
                width: 16; height: 16; radius: 8
                anchors.verticalCenter: parent.verticalCenter
                color: modelData.problems > 0 ? "#e0241f" : (modelData.warnings > 0 ? "#e0a040" : "#14a24c")
            }
            Text {
                text: modelData.name
                color: "#eeeeee"; font.pixelSize: 13; font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                visible: card.isFocus
                text: qsTr("selected camera")
                color: "#4a9eff"; font.pixelSize: 11; font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: modelData.summary
                color: modelData.problems > 0 ? "#f2574f" : (modelData.warnings > 0 ? "#e8b86a" : "#3dbb78"); font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: modelData.time + (modelData.firmware !== "" ? "   " + modelData.firmware : "")
                color: "#667788"; font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Column {
            id: body
            visible: card.isOpen
            x: 14
            y: head.y + head.height + 8
            width: card.width - 28
            spacing: 3

            Row {
                spacing: 8

                // Opens this camera's own web page in the browser, the same as the tile's right-click "Open camera web UI".
                Rectangle {
                    id: webBtn
                    visible: modelData.camIp !== undefined && modelData.camIp !== ""
                    width: webText.implicitWidth + 20
                    height: 24
                    radius: 4
                    color: webArea.pressed ? "#2a3a4a" : (webArea.containsMouse ? "#22303d" : "#1a242d")
                    border.width: 1
                    border.color: webArea.containsMouse ? "#00f5d4" : "#2a3540"
                    Text {
                        id: webText
                        anchors.centerIn: parent
                        text: qsTr("Open camera web page")
                        color: webArea.containsMouse ? "#00f5d4" : "#c8d2da"
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: webArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: WebBrowser.open("http://" + modelData.camIp + (modelData.camPort > 0 && modelData.camPort !== 80 ? ":" + modelData.camPort : ""))
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 500
                        ToolTip.text: qsTr("Open %1 in your browser (the same as the right-click item on a tile)").arg(modelData.camIp)
                    }
                }

                // Checks only this camera again (read-only). The big Refresh button of the window checks every camera.
                Rectangle {
                    id: againBtn
                    width: againText.implicitWidth + 20
                    height: 24
                    radius: 4
                    opacity: list.busy ? 0.45 : 1.0
                    color: againArea.pressed && !list.busy ? "#2a3a4a" : (againArea.containsMouse && !list.busy ? "#22303d" : "#1a242d")
                    border.width: 1
                    border.color: againArea.containsMouse && !list.busy ? "#00f5d4" : "#2a3540"
                    Text {
                        id: againText
                        anchors.centerIn: parent
                        text: qsTr("Check this camera again")
                        color: againArea.containsMouse && !list.busy ? "#00f5d4" : "#c8d2da"
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: againArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !list.busy
                        onClicked: list.recheck(modelData.key)
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 500
                        ToolTip.text: qsTr("Ask only this camera again (read-only). The Refresh button at the top checks every camera in the list.")
                    }
                }
            }

            Repeater {
                model: modelData.items
                delegate: Row {
                    width: body.width
                    spacing: 8
                    Text { text: list.stateMark(modelData.state); color: list.stateColor(modelData.state); font.pixelSize: 12; font.bold: true; width: 14 }
                    Text { text: modelData.label; color: "#dddddd"; font.pixelSize: 12; width: 170; wrapMode: Text.Wrap }
                    Text {
                        text: modelData.detail
                        color: modelData.state === "problem" ? "#f2574f" : (modelData.state === "warning" ? "#e8b86a" : "#8899aa")
                        font.pixelSize: 12
                        width: body.width - 14 - 170 - 16
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: list.results.length === 0
        text: qsTr("No camera has been checked yet. Right-click a tile and choose \"Check detection setup\".")
        color: "#8899aa"
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        width: parent.width - 40
    }
}
