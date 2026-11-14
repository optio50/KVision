import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0

// Shows what the read-only "Check detection setup" found: one card per camera checked since KVision started (the
// newest result for each), and the full list for the card clicked. Opened from a tile's right-click menu or from
// the settings window. It never changes anything on a camera or recorder.
Window {
    id: win

    width: 780
    height: 520
    minimumWidth: 520
    minimumHeight: 300
    color: "#0f151b"
    title: qsTr("Detection setup check")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    // The camera whose card is open when the window appears (its key), or "" for the list only.
    property string focusKey: ""
    property var results: []
    property string openKey: ""

    // The camera that was right-clicked stays first in the list, shaded and open, whatever else is checked.
    function reload() {
        var all = HikvisionSetupCheck.results();
        if (win.focusKey !== "") {
            var mine = [];
            var others = [];
            for (var i = 0; i < all.length; ++i)
                (all[i].key === win.focusKey ? mine : others).push(all[i]);
            all = mine.concat(others);
        }
        win.results = all;
    }

    // Asks the cameras again (read-only). The big Refresh button checks every camera in the list (the list holds every camera
    // checked since KVision started), or, if the list is empty, every camera that is switched on for detection. A card's own
    // small button checks only that camera. The list updates by itself as each answer arrives.
    function checkAgain() {
        if (typeof rootWindow === "undefined" || !rootWindow)
            return;
        if (win.results.length === 0) {
            rootWindow.checkDetectionSetup("");
        } else {
            for (var i = 0; i < win.results.length; ++i)
                rootWindow.checkDetectionSetup(win.results[i].key);
        }
        win.reload();
    }

    function checkOne(key) {
        if (typeof rootWindow === "undefined" || !rootWindow)
            return;
        rootWindow.checkDetectionSetup(key);
        win.reload();
    }

    function stateColor(state) {
        return state === "ok" ? "#2ecc71" : (state === "problem" ? "#ff5a36" : (state === "note" || state === "warning" ? "#e0a040" : (state === "off" ? "#667788" : "#8899aa")));
    }

    function stateMark(state) {
        return state === "ok" ? "\u2713" : (state === "problem" ? "\u2717" : (state === "note" || state === "warning" ? "!" : (state === "off" ? "\u2013" : "?")));
    }

    onVisibleChanged: {
        if (visible) {
            win.openKey = win.focusKey;
            win.reload();
            list.positionViewAtBeginning();
        }
    }

    onClosing: {
        win.destroy();
        if (typeof rootWindow !== "undefined" && rootWindow)
            rootWindow.triggerGcDeferred();
    }

    Connections {
        target: HikvisionSetupCheck
        onResultReady: win.reload()
        onQueueChanged: win.reload()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true

            Text {
                text: HikvisionSetupCheck.pending > 0
                      ? qsTr("Checking... %1 left").arg(HikvisionSetupCheck.pending)
                      : qsTr("%1 camera(s) checked since KVision started").arg(win.results.length)
                color: "#8899aa"
                font.pixelSize: 12
            }

            Item { Layout.fillWidth: true }

            Button {
                text: qsTr("Refresh")
                enabled: HikvisionSetupCheck.pending === 0
                onClicked: win.checkAgain()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: qsTr("Check every camera in the list again (read-only), so the cards show what the cameras say now. Each card has its own button for a single camera.")
            }
        }

        SetupCheckList {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            results: win.results
            focusKey: win.focusKey
            busy: HikvisionSetupCheck.pending > 0
            onRecheck: win.checkOne(key)
            openKey: win.openKey
            onOpenKeyChanged: win.openKey = openKey
        }
    }
}
