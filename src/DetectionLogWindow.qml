import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Utils 1.0

// A small window that shows the newest entries of the detection log (logs/Detection.log). It opens
// with 10, and Load more adds 25 older ones. Opened from a tile's right-click menu.
Window {
    id: logWin

    width: 1080
    height: 460
    // Never narrower than the controls need (the filter row and the Load button), whatever the names are
    minimumWidth: Math.max(850, content.implicitWidth + 24)
    minimumHeight: 240
    color: "#0f151b"
    title: qsTr("Detection events")
    flags: Qt.Window | Qt.WindowStaysOnTopHint

    // The address of the camera the window was opened from, and its name for the checkbox text.
    property string cameraIp: ""
    property string cameraName: ""
    readonly property int firstPage: 10
    readonly property int pageSize: 25
    readonly property int leadInSeconds: 10 // playback starts this long before the logged moment

    property var entries: []
    property bool more: false
    property int total: -1 // matching entries when a filter is used, else -1

    // The time range is picked as a number of hours back from now, or from the start of today or yesterday.
    readonly property var rangeChoices: [
        { "label": qsTr("All time"), "hours": 0 },
        { "label": qsTr("Last hour"), "hours": 1 },
        { "label": qsTr("Last 3 hours"), "hours": 3 },
        { "label": qsTr("Last 12 hours"), "hours": 12 },
        { "label": qsTr("Last 24 hours"), "hours": 24 },
        { "label": qsTr("Today"), "hours": -1 },
        { "label": qsTr("Yesterday"), "hours": -2 },
        { "label": qsTr("Last 7 days"), "hours": 168 }
    ]
    // The targets and types that can be picked. Each list is ticked in a pop-up; ticking none means all of them.
    readonly property var targetChoices: [
        { "label": qsTr("Human"), "key": "human" },
        { "label": qsTr("Vehicle"), "key": "vehicle" },
        { "label": qsTr("Animal"), "key": "animal" },
        { "label": qsTr("Other"), "key": "other" }
    ]
    // The types hold the words the log uses for them (the last one is several words, joined with commas).
    readonly property var kindChoices: [
        { "label": qsTr("Line crossing"), "key": "Line crossing" },
        { "label": qsTr("Intrusion"), "key": "Intrusion" },
        { "label": qsTr("Region entrance"), "key": "Region entrance" },
        { "label": qsTr("Region exit"), "key": "Region exit" },
        { "label": qsTr("Tracking"), "key": "Tracking" },
        { "label": qsTr("Motion"), "key": "Motion" },
        { "label": qsTr("Face detection"), "key": "Face detection" },
        { "label": qsTr("Other smart events"), "key": "Loitering,People gathering,Rapid movement,Parking,Unattended object,Object removed" }
    ]

    // What can be left out (the opposite of the two lists above). Ticked keys are kept in hiddenTargets / hiddenKinds;
    // the ones to show are kept in shownTargets / shownKinds.
    readonly property var hideTargetChoices: [
        { "label": qsTr("Human"), "key": "human" },
        { "label": qsTr("Vehicle"), "key": "vehicle" },
        { "label": qsTr("Animal"), "key": "animal" },
        { "label": qsTr("Other"), "key": "other" },
        { "label": qsTr("Unnamed motion"), "key": "unnamed" }
    ]
    readonly property var hideKindChoices: kindChoices
    property var shownTargets: ({})
    property var shownKinds: ({})
    property var hiddenTargets: ({})
    property var hiddenKinds: ({})

    // The keys of the ticked choices, joined with commas.
    function hiddenList(choices, ticked) {
        var out = [];
        for (var i = 0; i < choices.length; ++i)
            if (ticked[choices[i].key])
                out.push(choices[i].key);
        return out.join(",");
    }

    function tickedCount(ticked) {
        var n = 0;
        for (var k in ticked)
            if (ticked[k])
                ++n;
        return n;
    }

    function rangeFromMs() {
        var h = rangeBox.currentIndex >= 0 ? logWin.rangeChoices[rangeBox.currentIndex].hours : 0;
        var now = new Date();
        if (h === 0) return 0;
        if (h === -1 || h === -2) {
            var d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
            return d.getTime() - (h === -2 ? 86400000 : 0);
        }
        return now.getTime() - h * 3600000;
    }

    function rangeToMs() {
        var h = rangeBox.currentIndex >= 0 ? logWin.rangeChoices[rangeBox.currentIndex].hours : 0;
        if (h === -2) {
            var now = new Date();
            return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() - 1;
        }
        return 0;
    }

    function load(reset) {
        var skip = reset ? 0 : logWin.entries.length;
        var r = HikvisionEvents.readDetections(skip, reset ? logWin.firstPage : logWin.pageSize, Context.configDirPath(),
                                               onlyThisCamera.checked ? logWin.cameraIp : "",
                                               logWin.rangeFromMs(), logWin.rangeToMs(),
                                               logWin.hiddenList(logWin.targetChoices, logWin.shownTargets),
                                               logWin.hiddenList(logWin.kindChoices, logWin.shownKinds),
                                               logWin.hiddenList(logWin.hideTargetChoices, logWin.hiddenTargets),
                                               logWin.hiddenList(logWin.hideKindChoices, logWin.hiddenKinds));
        logWin.total = r.total;
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

    // True when the recorder is known to have no video that old any more. Unknown (not asked, or no answer) is never "gone".
    function videoGone(entry) {
        var rev = HikvisionRecordingSpan.revision; // makes bindings ask again when new answers arrive
        if (!logWin.canPlay(entry))
            return false;
        var oldest = HikvisionRecordingSpan.oldestMs(entry.recorderIp, entry.channel);
        return oldest > 0 && (entry.epochMs - logWin.leadInSeconds * 1000) < oldest;
    }

    function playEntry(entry) {
        if (!logWin.canPlay(entry))
            return;
        if (typeof rootWindow === "undefined" || !rootWindow)
            return;
        if (!rootWindow.openPlaybackAt(entry.recorderIp, entry.channel, entry.epochMs - logWin.leadInSeconds * 1000))
            logWin.notice = qsTr("This camera's recorder is not in the saved list");
        else if (logWin.videoGone(entry))
            logWin.notice = qsTr("The recorder no longer has video from that time, so playback may be empty");
        else
            logWin.notice = "";
    }

    property string notice: ""
    property bool loading: false
    property bool ready: false

    // The window is already on screen before the log is read, so the read does not hold the menu closed.
    function loadWhenShown() {
        logWin.loading = true;
        logWin.ready = false;
        showLoad.start();
    }

    // Opens the viewer on the picture of the entry clicked. The pictures are in time order, oldest first, so the right
    // arrow always goes to the next newest picture and the left arrow to an older one (the list itself shows the newest
    // entry at the top). Entries with no picture are skipped, and a tracking entry's snapshots run oldest to newest.
    function showPicture(entry) {
        if (entry.picture === "")
            return;
        var items = [];
        var start = 0;
        // One picture file serves every log line of the same camera, second and kind, and each line names its own box: a
        // target that is still being classified is reported several times with a moving box, and the camera draws its
        // frame for one of them. So the viewer is given all the boxes of a picture and judges the picture by any of them.
        var boxesOf = {};
        for (var j = 0; j < logWin.entries.length; ++j) {
            var q = logWin.entries[j];
            if (q.picture !== "" && q.box && q.box.length >= 4) {
                if (!boxesOf[q.picture])
                    boxesOf[q.picture] = [];
                boxesOf[q.picture].push(q.box);
            }
        }
        for (var i = logWin.entries.length - 1; i >= 0; --i) {
            var e = logWin.entries[i];
            if (e.picture === "")
                continue;
            var pics = (e.pictures && e.pictures.length > 0) ? e.pictures : [e.picture];
            if (e.raw === entry.raw && e.picture === entry.picture)
                start = items.length;
            for (var k = 0; k < pics.length; ++k)
                items.push({ "path": pics[k], "boxes": boxesOf[pics[k]] || [], "epochMs": e.epochMs + k * 1000, "camera": e.camera, "channel": e.channel, "kind": e.kind,
                             "entryIndex": i, "ip": e.ip, "recorderIp": e.recorderIp, "source": e.source,
                             "box": (pics.length === 1 || k === 0) ? e.box : [], "poly": (pics.length === 1 || k === 0) ? e.poly : [], "zone": e.zone,
                             "caption": e.time + "   " + e.target + "   " + e.kind + (e.zone > 0 ? " (" + qsTr("zone %1").arg(e.zone) + ")" : "") + "   " + e.camera
                                        + (e.source === "NVR" ? "   [" + qsTr("picture from the NVR") + "]" : (e.source === "camera" ? "   [" + qsTr("picture from the camera") + "]" : ""))
                                        + (pics.length > 1 ? "   (" + (k + 1) + "/" + pics.length + ")" : "") });
        }
        // Nothing else refers to a window created with no parent, and the garbage collector (which the app runs after
        // closing windows and every hour) would remove it while it is open, so it is kept in a list until it closes.
        var w = pictureViewer.createObject(null, { "items": items, "shown": start });
        if (w) {
            logWin.viewers.push(w);
            w.shownChanged.connect(function() {
                var it = w.items[w.shown];
                if (it)
                    logWin.selectEntry(it.entryIndex);
            });
            w.closed.connect(function() {
                var i = logWin.viewers.indexOf(w);
                if (i >= 0)
                    logWin.viewers.splice(i, 1);
            });
            if (items[start])
                logWin.selectEntry(items[start].entryIndex);
            w.show();
            // Cinnamon keeps the events window in front of a new always-on-top window unless this one
            // asks to be raised after it is on screen. MATE already puts the new window in front.
            w.raise();
            w.requestActivate();
            Qt.callLater(function() {
                if (!w)
                    return;
                w.raise();
                w.requestActivate();
            });
        }
    }

    // The row of the picture on screen. Contain leaves a row that is already visible where it is.
    function selectEntry(index) {
        if (index < 0 || index >= entries.length)
            return;
        list.currentIndex = index;
        list.positionViewAtIndex(index, ListView.Contain);
    }

    property var viewers: []

    Component {
        id: pictureViewer
        Window {
            id: pv
            // Every picture in the list as {path, caption}, oldest first; Right goes to the next newest, Left to an older one.
            property var items: []
            property int shown: 0
            property bool showMarks: true
            // 1 if the camera's own picture already has the red frame, 0 if not, -1 if it cannot be told; looked up per picture
            property int hasFrame: -1
            signal closed()
            onShownChanged: { pv.updateFrame(); pv.resetZoom() }
            Component.onCompleted: pv.updateFrame()
            // The alert often names only the first four corners. The saved rule is the whole zone.
            function zonePoly(it) {
                if (!it || !it.poly || it.poly.length < 4)
                    return [];
                var full = HikvisionEvents.completedZoneFor(it.ip || "", it.recorderIp || "", it.channel || 0,
                                                            it.kind || "", it.source || "", it.zone || 0, it.poly);
                return (full && full.length > it.poly.length) ? full : it.poly;
            }
            function updateFrame() {
                var it = pv.items.length > 0 ? pv.items[pv.shown] : null;
                if (!it || !it.box || it.box.length < 4) { pv.hasFrame = -1; return; }
                var cands = (it.boxes && it.boxes.length > 0) ? it.boxes.slice() : [];
                var own = false;
                for (var c = 0; c < cands.length; ++c) {
                    if (cands[c][0] === it.box[0] && cands[c][1] === it.box[1] && cands[c][2] === it.box[2] && cands[c][3] === it.box[3])
                        own = true;
                }
                if (!own)
                    cands.push(it.box);
                // 1 as soon as one box has the camera's red outline; 0 when at least one could be told and none has it
                var verdict = -1;
                for (var n = 0; n < cands.length; ++n) {
                    var v = HikvisionEvents.pictureHasFrame(it.path, cands[n][0], cands[n][1], cands[n][2], cands[n][3]);
                    if (v === 1) { verdict = 1; break; }
                    if (v === 0) verdict = 0;
                }
                pv.hasFrame = verdict;
            }
            // We draw only where the camera drew nothing itself (a picture that has the frame is left as it is).
            // The checkbox is the same test without the tick, so it is hidden when this picture has nothing for KVision to draw.
            readonly property bool marksAvailable: pv.items.length > 0 && pv.hasFrame !== 1
                                                   && ((pv.items[pv.shown].box && pv.items[pv.shown].box.length >= 4)
                                                       || (pv.items[pv.shown].poly && pv.items[pv.shown].poly.length >= 6))
            readonly property bool drawMarks: pv.showMarks && pv.marksAvailable
            width: 960
            height: 600
            minimumWidth: 320
            minimumHeight: 240
            color: "#0f151b"
            title: qsTr("Event picture")
            flags: Qt.Window | Qt.WindowStaysOnTopHint
            onClosing: { pv.closed(); pv.destroy() }

            // Saves the picture on screen in the snapshot folder (Settings), like the snapshot button of a live tile: a folder
            // for the day, and a name made of the channel, camera, date and time. The kind of event is added to the name so
            // two events in the same second keep their own file.
            // zoomedOnly false saves the picture file as it is (the whole picture, nothing drawn on it). true saves what is on
            // screen now: the zoomed part, with the target box and zone if they are shown, named with "_zoomed".
            function saveSnapshot(zoomedOnly) {
                if (pv.items.length === 0)
                    return;
                var it = pv.items[pv.shown];
                var when = it.epochMs > 0 ? new Date(it.epochMs) : new Date();
                var path = Utils.snapshotSavePath("", it.channel, it.camera, when);
                var tag = String(it.kind || "").replace(/[^A-Za-z0-9]/g, "");
                if (tag !== "")
                    path = path.replace(/(\.[^.\/]+)$/, "_" + tag + "$1");
                if (zoomedOnly === true) {
                    path = path.replace(/(\.[^.\/]+)$/, "_zoomed$1");
                    // Keep the visible part at about the picture's own resolution (never more than 4 times the window).
                    var gain = Math.max(1, Math.min(4, pic.implicitWidth / Math.max(1, pic.paintedWidth)));
                    view.grabToImage(function(result) {
                        if (result.saveToFile(path)) {
                            saved.filePath = path;
                            saved.open();
                        } else {
                            saved.filePath = qsTr("(the picture could not be saved)");
                            saved.open();
                        }
                    }, Qt.size(Math.round(view.width * gain), Math.round(view.height * gain)));
                    return;
                }
                if (HikvisionEvents.copyPicture(it.path, path)) {
                    saved.filePath = path;
                    saved.open();
                } else {
                    saved.filePath = qsTr("(the picture could not be saved)");
                    saved.open();
                }
            }

            SnapshotSavedDialog {
                id: saved
                z: 99
            }

            // Zoomed in: ask which one. At 100% there is only the whole picture, so it is saved at once.
            function snapshotClicked() {
                if (pv.zoom > 1)
                    snapshotChoiceMenu.popup();
                else
                    pv.saveSnapshot(false);
            }
            Menu {
                id: snapshotChoiceMenu
                MenuItem {
                    text: qsTr("Save full image")
                    onTriggered: pv.saveSnapshot(false)
                }
                MenuItem {
                    text: qsTr("Save zoomed view")
                    onTriggered: pv.saveSnapshot(true)
                }
            }
            Shortcut { sequence: "S"; onActivated: pv.snapshotClicked() }
            Shortcut { sequence: "Left"; enabled: pv.shown > 0; onActivated: pv.shown-- }
            Shortcut { sequence: "Right"; enabled: pv.shown < pv.items.length - 1; onActivated: pv.shown++ }

            Text {
                id: cap
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: stepRow.left
                anchors.margins: 8
                anchors.verticalCenter: stepRow.verticalCenter
                text: pv.items.length > 0 ? pv.items[pv.shown].caption : ""
                color: "#eeeeee"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Row {
                id: stepRow
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6
                spacing: 6
                CheckBox {
                    id: marksBox
                    visible: pv.marksAvailable
                    checked: pv.showMarks
                    text: qsTr("Target and zone")
                    onToggled: pv.showMarks = checked
                    ToolTip.visible: hovered; ToolTip.delay: 500
                    ToolTip.text: pv.hasFrame === 1 ? qsTr("The camera drew its own frame on this picture, so nothing is added")
                                                  : qsTr("Draw the target box (red) and the zone (orange) the camera named, where its picture has no frame")
                    contentItem: Text {
                        leftPadding: marksBox.indicator.width + 6
                        text: marksBox.text
                        color: "#eeeeee"
                        font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: zoomOutBtn
                    implicitWidth: 30
                    text: "\u2212"
                    enabled: pv.zoom > 1
                    onClicked: pv.zoomAt(1 / 1.4, view.width / 2, view.height / 2)
                    ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Zoom out (- key, or the mouse wheel)")
                }
                Text {
                    text: Math.round(pv.zoom * 100) + "%"
                    color: "#cccccc"
                    font.pixelSize: 12
                    width: 44
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                    MouseArea {
                        anchors.fill: parent
                        onClicked: pv.resetZoom()
                        ToolTip.visible: containsMouse; ToolTip.delay: 500; ToolTip.text: qsTr("Click for the whole picture (0 key, or double-click the picture)")
                        hoverEnabled: true
                    }
                }
                Button {
                    id: zoomInBtn
                    implicitWidth: 30
                    text: "+"
                    enabled: pv.zoom < pv.maxZoom
                    onClicked: pv.zoomAt(1.4, view.width / 2, view.height / 2)
                    ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Zoom in (+ key, the mouse wheel, or double-click the picture). Drag the picture to move it.")
                }
                Button {
                    id: snapBtn
                    implicitWidth: 34
                    onClicked: pv.snapshotClicked()
                    ToolTip.visible: hovered; ToolTip.delay: 500
                    ToolTip.text: pv.zoom > 1 ? qsTr("Save this picture in the snapshot folder: the full image or the zoomed view (S key)")
                                              : qsTr("Save this picture in the snapshot folder (S key)")
                    contentItem: Image {
                        sourceSize: Qt.size(20, 20)
                        fillMode: Image.PreserveAspectFit
                        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + (snapBtn.hovered ? "%2300f5d4" : "%23ffffff") + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z'></path><circle cx='12' cy='13' r='4'></circle></svg>"
                    }
                }
                Button { visible: pv.items.length > 1; text: "\u2039"; enabled: pv.shown > 0; onClicked: pv.shown--
                         ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Older picture (Left key)") }
                Text { visible: pv.items.length > 1; text: (pv.shown + 1) + " / " + pv.items.length; color: "#cccccc"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                Button { visible: pv.items.length > 1; text: "\u203a"; enabled: pv.shown < pv.items.length - 1; onClicked: pv.shown++
                         ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Next newest picture (Right key)") }
            }
            // Zoom: the mouse wheel (around the pointer), the - and + buttons or keys, double-click to zoom in on a spot and again to
            // go back. Drag the picture to move it when zoomed in. 100% is the whole picture fitted in the window. The target box
            // and the zone are drawn again at every zoom, so they stay sharp and on the target.
            property real zoom: 1
            readonly property real maxZoom: 10
            // Keeps the picture itself (not the empty bars beside it) covering the view. When the picture is smaller than the view
            // in one direction (at 100% in a window of another shape) it stays centred in that direction.
            function clampPan() {
                var pw = pic.paintedWidth, ph = pic.paintedHeight;
                if (pw <= 0 || ph <= 0) {
                    pic.x = 0;
                    pic.y = 0;
                    return;
                }
                var ox = (pic.width - pw) / 2, oy = (pic.height - ph) / 2;
                pic.x = pw <= view.width ? (view.width - pw) / 2 - ox : Math.min(-ox, Math.max(view.width - pw - ox, pic.x));
                pic.y = ph <= view.height ? (view.height - ph) / 2 - oy : Math.min(-oy, Math.max(view.height - ph - oy, pic.y));
            }
            function zoomAt(factor, mx, my) {
                var z2 = Math.max(1, Math.min(pv.maxZoom, pv.zoom * factor));
                if (z2 === pv.zoom)
                    return;
                var k = z2 / pv.zoom;
                var nx = mx - (mx - pic.x) * k;
                var ny = my - (my - pic.y) * k;
                pv.zoom = z2;
                pic.x = nx;
                pic.y = ny;
                pv.clampPan();
                marks.requestPaint();
            }
            function resetZoom() {
                pv.zoom = 1;
                pic.x = 0;
                pic.y = 0;
                marks.requestPaint();
            }
            Shortcut { sequence: "+"; onActivated: pv.zoomAt(1.4, view.width / 2, view.height / 2) }
            Shortcut { sequence: "="; onActivated: pv.zoomAt(1.4, view.width / 2, view.height / 2) }
            Shortcut { sequence: "-"; onActivated: pv.zoomAt(1 / 1.4, view.width / 2, view.height / 2) }
            Shortcut { sequence: "0"; onActivated: pv.resetZoom() }

            Item {
                id: view
                anchors.top: stepRow.bottom
                anchors.topMargin: 6
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                clip: true

                Image {
                    id: pic
                    x: 0
                    y: 0
                    width: view.width * pv.zoom
                    height: view.height * pv.zoom
                    source: pv.items.length > 0 ? "file://" + pv.items[pv.shown].path : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: false
                    smooth: true
                    onWidthChanged: pv.clampPan()
                    onHeightChanged: pv.clampPan()
                    onPaintedWidthChanged: pv.clampPan()
                    onPaintedHeightChanged: pv.clampPan()

                    // The part of this item the picture really covers (it is centred and keeps its shape).
                    readonly property real shownW: paintedWidth
                    readonly property real shownH: paintedHeight
                    readonly property real offX: (width - paintedWidth) / 2
                    readonly property real offY: (height - paintedHeight) / 2
                }

                Canvas {
                    id: marks
                    anchors.fill: parent
                    visible: pv.drawMarks
                    onVisibleChanged: requestPaint()
                    Connections {
                        target: pv
                        onShownChanged: marks.requestPaint()
                        onHasFrameChanged: marks.requestPaint()
                    }
                    Connections {
                        target: pic
                        onPaintedWidthChanged: marks.requestPaint()
                        onPaintedHeightChanged: marks.requestPaint()
                        onStatusChanged: marks.requestPaint()
                        onXChanged: marks.requestPaint()
                        onYChanged: marks.requestPaint()
                    }
                    Connections {
                        target: HikvisionEvents
                        onZoneRulesReady: marks.requestPaint()
                    }
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        if (!pv.drawMarks || pic.shownW <= 0)
                            return;
                        var it = pv.items[pv.shown];
                        var poly = pv.zonePoly(it);
                        ctx.lineJoin = "round";
                        // the zone configured for this rule, in orange
                        if (poly && poly.length >= 6) {
                            ctx.beginPath();
                            for (var i = 0; i + 1 < poly.length; i += 2) {
                                var px = pic.x + pic.offX + poly[i] * pic.shownW, py = pic.y + pic.offY + poly[i + 1] * pic.shownH;
                                if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                            }
                            ctx.closePath();
                            ctx.strokeStyle = "#ff9500";
                            ctx.lineWidth = 2;
                            ctx.stroke();
                        }
                        // the target it reacted to, in red, a little larger than a pixel-thin box so it can be seen
                        if (it.box && it.box.length >= 4) {
                            var bx = pic.x + pic.offX + it.box[0] * pic.shownW, by = pic.y + pic.offY + it.box[1] * pic.shownH;
                            var bw = Math.max(8, it.box[2] * pic.shownW), bh = Math.max(8, it.box[3] * pic.shownH);
                            ctx.strokeStyle = "#ff2a2a";
                            ctx.lineWidth = 2;
                            ctx.strokeRect(bx, by, bw, bh);
                        }
                    }
                }

                MouseArea {
                    id: panArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: pv.zoom > 1 ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
                    property real lastX: 0
                    property real lastY: 0
                    onWheel: {
                        pv.zoomAt(wheel.angleDelta.y > 0 ? 1.25 : 0.8, wheel.x, wheel.y);
                        wheel.accepted = true;
                    }
                    onPressed: { lastX = mouse.x; lastY = mouse.y; }
                    onPositionChanged: {
                        if (!pressed || pv.zoom <= 1)
                            return;
                        pic.x += mouse.x - lastX;
                        pic.y += mouse.y - lastY;
                        lastX = mouse.x;
                        lastY = mouse.y;
                        pv.clampPan();
                    }
                    onDoubleClicked: {
                        if (pv.zoom > 1)
                            pv.resetZoom();
                        else
                            pv.zoomAt(3, mouse.x, mouse.y);
                    }
                }
            }
        }
    }

    function targetColor(target) {
        var t = String(target).toLowerCase();
        return t === "human" ? "#ff5a36" : (t === "vehicle" ? "#2d8cff" : (t === "face" ? "#b45cff" : "#2ecc71"));
    }

    onVisibleChanged: {
        if (visible)
            logWin.loadWhenShown();
    }

    Timer {
        id: showLoad
        interval: 1
        repeat: false
        onTriggered: {
            if (!logWin.visible)
                return;
            logWin.load(true);
            logWin.loading = false;
            logWin.ready = true;
            if (typeof rootWindow !== "undefined" && rootWindow)
                HikvisionRecordingSpan.refresh(rootWindow.hikvisionRecordersJson || "[]");
        }
    }

    onClosing: {
        logWin.destroy();
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            CheckBox {
                id: onlyThisCamera
                visible: logWin.cameraIp !== ""
                Layout.fillWidth: true
                Layout.preferredWidth: 190
                Layout.minimumWidth: 90
                checked: logWin.cameraIp !== ""
                text: qsTr("Only this camera") + (logWin.cameraName !== "" ? " (" + logWin.cameraName + ")" : "")
                onToggled: if (logWin.ready) logWin.load(true)
                contentItem: Text {
                    leftPadding: onlyThisCamera.indicator.width + 6
                    elide: Text.ElideRight
                    text: onlyThisCamera.text
                    color: "#eeeeee"
                    font.pixelSize: 12
                    verticalAlignment: Text.AlignVCenter
                }
            }

            ComboBox {
                id: rangeBox
                model: logWin.rangeChoices.map(function(c) { return c.label; })
                currentIndex: 0
                implicitWidth: 130
                onActivated: logWin.load(true)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: qsTr("Only events in this time range")
            }

            Button {
                id: showTargetsButton
                readonly property int n: logWin.tickedCount(logWin.shownTargets)
                text: n > 0 ? qsTr("Targets (%1)").arg(n) : qsTr("All targets")
                implicitWidth: 130
                onClicked: showTargetsPopup.opened ? showTargetsPopup.close() : showTargetsPopup.open()
                ToolTip.visible: hovered && !showTargetsPopup.opened
                ToolTip.delay: 600
                ToolTip.text: qsTr("Tick the targets to show. Several can be ticked; none ticked shows them all.")
                TickListPopup {
                    id: showTargetsPopup
                    y: parent.height + 4
                    choices: logWin.targetChoices
                    ticked: logWin.shownTargets
                    onTickChanged: {
                        var t = Object.assign({}, logWin.shownTargets);
                        t[key] = checked;
                        logWin.shownTargets = t;
                    }
                    onCleared: {
                        logWin.shownTargets = ({});
                    }
                    onApplied: logWin.load(true)
                }
            }

            Button {
                id: showKindsButton
                readonly property int n: logWin.tickedCount(logWin.shownKinds)
                text: n > 0 ? qsTr("Types (%1)").arg(n) : qsTr("All types")
                implicitWidth: 130
                onClicked: showKindsPopup.opened ? showKindsPopup.close() : showKindsPopup.open()
                ToolTip.visible: hovered && !showKindsPopup.opened
                ToolTip.delay: 600
                ToolTip.text: qsTr("Tick the types of event to show. Several can be ticked; none ticked shows them all.")
                TickListPopup {
                    id: showKindsPopup
                    y: parent.height + 4
                    choices: logWin.kindChoices
                    ticked: logWin.shownKinds
                    onTickChanged: {
                        var t = Object.assign({}, logWin.shownKinds);
                        t[key] = checked;
                        logWin.shownKinds = t;
                    }
                    onCleared: {
                        logWin.shownKinds = ({});
                    }
                    onApplied: logWin.load(true)
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                visible: logWin.total >= 0
                text: qsTr("%1 events").arg(logWin.total)
                color: "#8899aa"
                font.pixelSize: 12
            }

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
                Text { width: parent.width - 350 - 100 - 80 - 90; height: parent.height; text: qsTr("Camera"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
                Text { width: 100; height: parent.height; text: qsTr("Address"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                Text { width: 90; height: parent.height; text: qsTr("Source"); color: "#00f5d4"; font.bold: true; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
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
            currentIndex: -1
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                id: row
                width: list.width
                height: 26
                color: index === list.currentIndex ? "#14332e"
                       : (rowArea.containsMouse && logWin.canPlay(modelData) ? "#22303a" : (index % 2 === 0 ? "#141b22" : "transparent"))
                border.width: index === list.currentIndex ? 1 : 0
                border.color: "#00f5d4"
                readonly property bool playable: logWin.canPlay(modelData)
                readonly property bool gone: logWin.videoGone(modelData)

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
                        width: parent.width - 350 - 100 - 80 - 90; height: parent.height
                        text: modelData.camera + (modelData.received !== "" ? "   (late)" : "")
                        color: modelData.received !== "" ? "#aa9966" : "#eeeeee"; font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                    }
                    Text {
                        width: 100; height: parent.height
                        text: modelData.ip
                        color: "#8899aa"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter
                    }
                    Text {
                        width: 90; height: parent.height
                        // The device the report came from. Its picture, when it has one, comes from the same device (the link or
                        // snapshot is only ever fetched from the connection's own address). Lines written before this show a dash.
                        text: modelData.source === "NVR" ? qsTr("NVR") : (modelData.source === "camera" ? qsTr("Camera") : "\u2013")
                        ToolTip.visible: srcArea.containsMouse && modelData.source !== ""
                        ToolTip.text: qsTr("The report, and its picture if it has one, came from the %1").arg(modelData.source === "NVR" ? qsTr("NVR") : qsTr("camera"))
                        MouseArea { id: srcArea; anchors.fill: parent; hoverEnabled: true }
                        color: modelData.source === "NVR" ? "#e0a040" : (modelData.source === "camera" ? "#00f5d4" : "#445566")
                        font.pixelSize: 12; verticalAlignment: Text.AlignVCenter
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
                                ToolTip.text: modelData.source === "NVR" ? qsTr("Show the picture the NVR sent with this event")
                                            : (modelData.source === "camera" ? qsTr("Show the picture the camera sent with this event")
                                                                             : qsTr("Show the picture kept with this event"))
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
                            color: playArea.containsMouse ? (row.gone ? "#667788" : "#00f5d4") : "#2a3540"
                            opacity: row.gone ? 0.45 : 1.0
                            Text {
                                anchors.centerIn: parent
                                text: "\u25B6"
                                font.pixelSize: 10
                                color: playArea.containsMouse ? "#0f151b" : (row.gone ? "#8899aa" : "#00f5d4")
                            }
                            MouseArea {
                                id: playArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: logWin.playEntry(modelData)
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 500
                                ToolTip.text: row.gone ? qsTr("The recorder no longer has video from this time (it keeps only the newest)")
                                                       : qsTr("Play the recording %1 seconds before this moment").arg(logWin.leadInSeconds)
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
                text: qsTr("Leave out:")
                color: "#8899aa"
                font.pixelSize: 12
            }

            Button {
                id: hideTargetsButton
                readonly property int n: logWin.tickedCount(logWin.hiddenTargets)
                text: n > 0 ? qsTr("Targets (%1)").arg(n) : qsTr("Targets")
                implicitWidth: 120
                onClicked: hideTargetsPopup.opened ? hideTargetsPopup.close() : hideTargetsPopup.open()
                ToolTip.visible: hovered && !hideTargetsPopup.opened
                ToolTip.delay: 600
                ToolTip.text: qsTr("Tick the targets to leave out of the list. \"Unnamed motion\" is motion that did not say what moved.")
                TickListPopup {
                    id: hideTargetsPopup
                    y: -height - 4
                    choices: logWin.hideTargetChoices
                    ticked: logWin.hiddenTargets
                    onTickChanged: {
                        var t = Object.assign({}, logWin.hiddenTargets);
                        t[key] = checked;
                        logWin.hiddenTargets = t;
                    }
                    onCleared: {
                        logWin.hiddenTargets = ({});
                    }
                    onApplied: logWin.load(true)
                }
            }

            Button {
                id: hideKindsButton
                readonly property int n: logWin.tickedCount(logWin.hiddenKinds)
                text: n > 0 ? qsTr("Types (%1)").arg(n) : qsTr("Types")
                implicitWidth: 120
                onClicked: hideKindsPopup.opened ? hideKindsPopup.close() : hideKindsPopup.open()
                ToolTip.visible: hovered && !hideKindsPopup.opened
                ToolTip.delay: 600
                ToolTip.text: qsTr("Tick the types of event to leave out of the list")
                TickListPopup {
                    id: hideKindsPopup
                    y: -height - 4
                    choices: logWin.hideKindChoices
                    ticked: logWin.hiddenKinds
                    onTickChanged: {
                        var t = Object.assign({}, logWin.hiddenKinds);
                        t[key] = checked;
                        logWin.hiddenKinds = t;
                    }
                    onCleared: {
                        logWin.hiddenKinds = ({});
                    }
                    onApplied: logWin.load(true)
                }
            }

            Text {
                text: logWin.loading ? qsTr("Loading events") : qsTr("%1 shown").arg(logWin.entries.length)
                color: logWin.loading ? "#00f5d4" : "#8899aa"
                font.pixelSize: 12
            }

            Text {
                visible: logWin.notice !== ""
                Layout.fillWidth: true
                Layout.preferredWidth: 60
                elide: Text.ElideRight
                text: logWin.notice
                color: "#e0a040"
                font.pixelSize: 12
                ToolTip.visible: noticeArea.containsMouse
                ToolTip.text: logWin.notice
                MouseArea { id: noticeArea; anchors.fill: parent; hoverEnabled: true }
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
