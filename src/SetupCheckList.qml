import QtQuick 2.11
import QtQuick.Controls 2.4

// The list of check results: one card per camera, the card clicked shows every line the check found.
ListView {
    id: list

    property var results: []
    property string openKey: ""
    property string focusKey: "" // the camera of interest: shaded, and always listed first

    clip: true
    model: results
    spacing: 4
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}

    function stateColor(state) {
        return state === "ok" ? "#2ecc71" : (state === "problem" ? "#ff5a36" : (state === "note" ? "#e0a040" : "#8899aa"));
    }

    function stateMark(state) {
        return state === "ok" ? "\u2713" : (state === "problem" ? "\u2717" : (state === "note" ? "!" : "?"));
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
        border.color: isFocus ? "#4a9eff" : (modelData.problems > 0 ? "#5a3a32" : "#1f3a2c")

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
                color: modelData.problems > 0 ? "#ff5a36" : "#2ecc71"
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
                color: modelData.problems > 0 ? "#ff8a6a" : "#6fd39a"; font.pixelSize: 12
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

            Repeater {
                model: modelData.items
                delegate: Row {
                    width: body.width
                    spacing: 8
                    Text { text: list.stateMark(modelData.state); color: list.stateColor(modelData.state); font.pixelSize: 12; font.bold: true; width: 14 }
                    Text { text: modelData.label; color: "#dddddd"; font.pixelSize: 12; width: 170; wrapMode: Text.Wrap }
                    Text {
                        text: modelData.detail
                        color: modelData.state === "problem" ? "#ff8a6a" : "#8899aa"
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
