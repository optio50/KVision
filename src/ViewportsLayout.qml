import QtQml 2.11
import QtQuick 2.11
import QtQuick.Layouts 1.11
import QtMultimedia 5.11
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Models 1.0
import CCTV_Viewer.Hikvision 1.0
import QtQuick.Controls 2.4

FocusScope {
    id: root

    property var size: model.size
    property var model: ViewportsLayoutModel {}
    property string color: "black"
    property int pendingSwapSourceIndex: -1

    Component.onDestruction: {
        playerPool.releaseAll();
    }

    // Keeps a menu inside the window. Qt places it before its entries have their final size (some only appear when the
    // menu is about to show), so the first time it can end up partly off screen. This moves it back once the size is known.
    function fitMenu(m) {
        if (!m || !m.visible || !m.parent)
            return;
        var p = m.parent.mapToItem(null, m.x, m.y);
        var dx = 0, dy = 0;
        if (p.x + m.width > rootWindow.width - 6)
            dx = rootWindow.width - 6 - m.width - p.x;
        if (p.y + m.height > rootWindow.height - 6)
            dy = rootWindow.height - 6 - m.height - p.y;
        if (p.x + dx < 6)
            dx = 6 - p.x;
        if (p.y + dy < 6)
            dy = 6 - p.y;
        if (dx !== 0)
            m.x += dx;
        if (dy !== 0)
            m.y += dy;
    }
    property var fitPending: []
    Timer {
        id: fitTimer
        interval: 40
        repeat: false
        onTriggered: {
            var l = root.fitPending;
            root.fitPending = [];
            for (var i = 0; i < l.length; i++)
                root.fitMenu(l[i]);
        }
    }
    function popupFitted(m, item, x, y) {
        if (item)
            m.popup(item, x, y);
        else
            m.popup();
        root.fitMenu(m);
        var l = root.fitPending;
        l.push(m);
        root.fitPending = l;
        fitTimer.restart(); // and again once the entries have settled
    }

    // Opens a sub-menu beside its menu item: to the right, or to the left when there is no room on the right.
    function popupBeside(sub, item) {
        var p = item.mapToItem(null, 0, 0);
        var w = Math.max(sub.implicitWidth, sub.width, 200);
        var h = Math.max(sub.implicitHeight, sub.height);
        var x = (p.x + item.width + w > rootWindow.width - 6) ? -w : item.width;
        var y = 0;
        if (p.y + h > rootWindow.height - 6)
            y = rootWindow.height - 6 - h - p.y; // no room below: slide up so the last item is still on screen
        if (p.y + y < 6)
            y = 6 - p.y;
        root.popupFitted(sub, item, x, y);
    }

    // Quick tools > Noise filter: the camera's own "Environmental Noise Filtering" switch. Read when the menu opens,
    // set the other way on a click. The flashing light and warning message reads follow it, on the same worker.
    property string noiseMenuIp: ""
    property string noiseMenuName: ""
    property bool noiseMenuLoading: false
    property string noiseReadIp: ""    // a read started only to show the tick, and to start the reads that follow it
    property var noiseKnown: ({})      // camera address -> {on: bool, none: bool, at: ms}
    property int noiseKnownRev: 0
    function noiseIsOn(ip) {
        var rev = root.noiseKnownRev;
        return !!ip && !!root.noiseKnown[ip] && root.noiseKnown[ip].on;
    }
    function noiseHas(ip) {
        var rev = root.noiseKnownRev;
        return !!ip && !(root.noiseKnown[ip] && root.noiseKnown[ip].none);
    }
    // True only after the camera has answered and it has the switch. Until then the menu row stays gray.
    function noiseReady(ip) {
        var rev = root.noiseKnownRev;
        return !!ip && !!root.noiseKnown[ip] && !root.noiseKnown[ip].none;
    }
    function refreshNoiseState(ip) {
        if (!ip || HikvisionBackup.ruleBusy || root.noiseMenuIp !== "")
            return;
        var k = root.noiseKnown[ip];
        if (k && Date.now() - k.at < 20000) {
            root.refreshStrobeState(ip);
            return;
        }
        if (HikvisionBackup.cameraCount() === 0) {
            root.noiseReadIp = ip;
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
            return;
        }
        HikvisionBackup.checkNoiseFilter(ip);
    }
    function toggleNoiseFilter(ip, name) {
        if (!ip || HikvisionBackup.ruleBusy)
            return;
        root.noiseMenuIp = ip;
        root.noiseMenuName = name || ip;
        rootWindow.showNotice(qsTr("Noise filter") + "\n" + root.noiseMenuName + "\n" + qsTr("asking the camera..."), "#00f5d4", 0);
        if (HikvisionBackup.cameraCount() === 0) {
            root.noiseMenuLoading = true;
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
            return;
        }
        HikvisionBackup.toggleNoiseFilter(ip);
    }
    // Quick tools > Flashing light: the camera's built-in strobe. Whether the camera has one is asked when the menu
    // opens (after the noise filter read, because the switches share one worker).
    property string strobeMenuIp: ""
    property string strobeMenuName: ""
    property bool strobeMenuLoading: false
    property var strobeKnown: ({})     // camera address -> {has: bool, at: ms}
    property int strobeKnownRev: 0
    function strobeHas(ip) {
        var rev = root.strobeKnownRev;
        return !!ip && !!root.strobeKnown[ip] && root.strobeKnown[ip].has;
    }
    function refreshStrobeState(ip) {
        if (!ip || HikvisionBackup.ruleBusy || root.noiseMenuIp !== "" || root.strobeMenuIp !== "")
            return;
        var k = root.strobeKnown[ip];
        if (k && Date.now() - k.at < 600000) {
            root.refreshWarnState(ip);
            return;
        }
        if (HikvisionBackup.cameraCount() === 0)
            return;
        HikvisionBackup.checkStrobe(ip);
    }
    function runStrobe(ip, name) {
        if (!ip || HikvisionBackup.ruleBusy)
            return;
        root.strobeMenuIp = ip;
        root.strobeMenuName = name || ip;
        rootWindow.showNotice(qsTr("Flashing light") + "\n" + root.strobeMenuName + "\n" + qsTr("asking the camera..."), "#00f5d4", 0);
        if (HikvisionBackup.cameraCount() === 0) {
            root.strobeMenuLoading = true;
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
            return;
        }
        HikvisionBackup.startStrobe(ip);
    }
    // Quick tools > Play Warning Message: the camera's own warning sound. Asked when the menu opens, after the flashing
    // light read (the switches share one worker).
    property string warnMenuIp: ""
    property string warnMenuName: ""
    property bool warnMenuLoading: false
    property var warnKnown: ({})       // camera address -> {has: bool, at: ms}
    property int warnKnownRev: 0
    function warnHas(ip) {
        var rev = root.warnKnownRev;
        return !!ip && !!root.warnKnown[ip] && root.warnKnown[ip].has;
    }
    function refreshWarnState(ip) {
        if (!ip || HikvisionBackup.ruleBusy || root.noiseMenuIp !== "" || root.strobeMenuIp !== "" || root.warnMenuIp !== "")
            return;
        var k = root.warnKnown[ip];
        if (k && Date.now() - k.at < 600000)
            return;
        if (HikvisionBackup.cameraCount() === 0)
            return;
        HikvisionBackup.checkWarning(ip);
    }
    function runWarning(ip, name) {
        if (!ip || HikvisionBackup.ruleBusy)
            return;
        root.warnMenuIp = ip;
        root.warnMenuName = name || ip;
        rootWindow.showNotice(qsTr("Warning message") + "\n" + root.warnMenuName + "\n" + qsTr("asking the camera..."), "#00f5d4", 0);
        if (HikvisionBackup.cameraCount() === 0) {
            root.warnMenuLoading = true;
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
            return;
        }
        HikvisionBackup.startWarning(ip);
    }
    // Quick tools > Camera settings: the Camera settings window (read only) opened on the camera that was clicked and read at once, with
    // its Status section (uptime, load, restarts, wear on moving parts) among the others. A window already open for that camera is
    // brought forward and read again.
    property var cameraSettingsWins: ({})
    function openCameraSettings(ip, name) {
        if (!ip)
            return;
        var open = root.cameraSettingsWins[ip];
        if (open) {
            open.show();
            open.raise();
            open.showCamera(ip);
            return;
        }
        var w = cameraSettingsComponent.createObject(rootWindow, { "startIp": ip });
        if (!w)
            return;
        var m = root.cameraSettingsWins;
        m[ip] = w;
        root.cameraSettingsWins = m;
        w.closing.connect(function() {
            var k = root.cameraSettingsWins;
            delete k[ip];
            root.cameraSettingsWins = k;
        });
        w.show();
    }
    // Quick tools > Reboot Camera: asks first (the camera goes offline for a minute or two), then restarts only that camera.
    property string rebootMenuIp: ""
    property string rebootMenuName: ""
    property bool rebootMenuLoading: false
    function askReboot(ip, name) {
        if (!ip || HikvisionBackup.ruleBusy)
            return;
        rebootConfirm.camIp = ip;
        rebootConfirm.camName = name || ip;
        rebootConfirm.open();
    }
    function runReboot(ip, name) {
        if (!ip || HikvisionBackup.ruleBusy)
            return;
        root.rebootMenuIp = ip;
        root.rebootMenuName = name || ip;
        rootWindow.showNotice(qsTr("Reboot camera") + "\n" + root.rebootMenuName + "\n" + qsTr("asking the camera..."), "#ff9f43", 0);
        if (HikvisionBackup.cameraCount() === 0) {
            root.rebootMenuLoading = true;
            HikvisionBackup.loadCameras(rootWindow.hikvisionRecordersJson || "[]", Context.config.fileName);
            return;
        }
        HikvisionBackup.rebootCamera(ip);
    }
    Connections {
        target: HikvisionBackup
        function onCamerasLoaded(cameras) {
            if (root.rebootMenuLoading && root.rebootMenuIp !== "") {
                root.rebootMenuLoading = false;
                HikvisionBackup.rebootCamera(root.rebootMenuIp);
            } else if (root.warnMenuLoading && root.warnMenuIp !== "") {
                root.warnMenuLoading = false;
                HikvisionBackup.startWarning(root.warnMenuIp);
            } else if (root.strobeMenuLoading && root.strobeMenuIp !== "") {
                root.strobeMenuLoading = false;
                HikvisionBackup.startStrobe(root.strobeMenuIp);
            } else if (root.noiseMenuLoading && root.noiseMenuIp !== "") {
                root.noiseMenuLoading = false;
                HikvisionBackup.toggleNoiseFilter(root.noiseMenuIp);
            } else if (root.noiseReadIp !== "" && root.noiseMenuIp === "" && !HikvisionBackup.ruleBusy) {
                var readIp = root.noiseReadIp;
                root.noiseReadIp = "";
                HikvisionBackup.checkNoiseFilter(readIp);
            }
        }
        function onNoiseFilterResult(ip, state, message) {
            if (state === "on" || state === "off" || state === "unavailable") {
                var k = root.noiseKnown;
                k[ip] = { "on": state === "on", "none": state === "unavailable", "at": Date.now() };
                root.noiseKnown = k;
                root.noiseKnownRev++;
            }
            if (root.noiseMenuIp === "")
                Qt.callLater(function() { root.refreshStrobeState(ip); });
            if (root.noiseMenuIp === "" || ip !== root.noiseMenuIp)
                return;
            var name = root.noiseMenuName;
            root.noiseMenuIp = "";
            var head = qsTr("Noise filter") + "\n" + name + "\n";
            if (state === "on")
                rootWindow.showNotice(head + qsTr("ON: ") + message, "#00ff66", 6000);
            else if (state === "off")
                rootWindow.showNotice(head + qsTr("OFF: ") + message, "#00f5d4", 6000);
            else
                rootWindow.showNotice(head + message, "#ff3333", 10000);
        }
        function onStrobeResult(ip, state, message) {
            if (state === "available" || state === "unavailable") {
                var k = root.strobeKnown;
                k[ip] = { "has": state === "available", "at": Date.now() };
                root.strobeKnown = k;
                root.strobeKnownRev++;
            }
            if (root.strobeMenuIp === "")
                Qt.callLater(function() { root.refreshWarnState(ip); });
            if (root.strobeMenuIp === "" || ip !== root.strobeMenuIp)
                return;
            var name = root.strobeMenuName;
            root.strobeMenuIp = "";
            var head = qsTr("Flashing light") + "\n" + name + "\n";
            if (state === "started")
                rootWindow.showNotice(head + message, "#00ff66", 6000);
            else
                rootWindow.showNotice(head + message, "#ff3333", 10000);
        }
        function onWarningResult(ip, state, message) {
            if (state === "available" || state === "unavailable") {
                var k = root.warnKnown;
                k[ip] = { "has": state === "available", "at": Date.now() };
                root.warnKnown = k;
                root.warnKnownRev++;
            }
            if (root.warnMenuIp === "" || ip !== root.warnMenuIp)
                return;
            var name = root.warnMenuName;
            root.warnMenuIp = "";
            var head = qsTr("Warning message") + "\n" + name + "\n";
            if (state === "started")
                rootWindow.showNotice(head + message, "#00ff66", 6000);
            else
                rootWindow.showNotice(head + message, "#ff3333", 10000);
        }
        function onRebootResult(ip, state, message) {
            if (root.rebootMenuIp === "" || ip !== root.rebootMenuIp)
                return;
            var name = root.rebootMenuName;
            root.rebootMenuIp = "";
            var head = qsTr("Reboot camera") + "\n" + name + "\n";
            if (state === "started" || state === "sent")
                rootWindow.showNotice(head + message, "#ff9f43", 12000);
            else
                rootWindow.showNotice(head + message, "#ff3333", 10000);
        }
    }

    QtObject {
        id: playerPool

        property var sharedPlayerComponent: null
        property var activePlayersMap: ({}) // index -> Player
        property var mediaErrorSlotsMap: ({}) // index -> function

        function acquirePlayer(index, parentContainer, viewportItem) {
            if (activePlayersMap[index] !== undefined) {
                releasePlayer(index);
            }

            if (!sharedPlayerComponent || sharedPlayerComponent.status !== Component.Ready)
                sharedPlayerComponent = Qt.createComponent("Player.qml");
            if (sharedPlayerComponent.status !== Component.Ready) {
                console.error("Failed to create Player: " + sharedPlayerComponent.errorString());
                return null;
            }
            var player = sharedPlayerComponent.createObject(root);
            if (!player)
                return null;

            player.parent = parentContainer;

            // Set bindings
            player.visible = Qt.binding(function() {
                return !!(root.visible && parentContainer && parentContainer.visible);
            });
            player.index = index;
            player.color = Qt.binding(function() { return root.color; });
            player.volume = Qt.binding(function() {
                var vItem = root.model.get(index);
                return vItem ? vItem.volume : 0.0;
            });
            player.muted = Qt.binding(function() {
                if (typeof generalSettings !== "undefined" && generalSettings.disableAudio) {
                    return true;
                }
                if (typeof rootWindow !== "undefined" && rootWindow.isPlaybackWindowOpen) {
                    return true;
                }
                return player.volume <= 0.0;
            });
            player.avOptions = Qt.binding(function() {
                var vItem = root.model.get(index);
                return vItem ? vItem.avFormatOptions : ({});
            });

            player.ignoreGlobalAVFormatOptions = Qt.binding(function() {
                var vItem = root.model.get(index);
                return vItem ? vItem.ignoreGlobalAVFormatOptions : false;
            });

            player.source = Qt.binding(function() {
                var vItem = root.model.get(index);
                if (!vItem) return "";
                var d2Failed = viewportItem.d2SecondaryUrlFailed;
                if (vItem.streamMode === 1) {
                    return vItem.url;
                } else if (vItem.streamMode === 2) {
                    return (String(vItem.secondaryUrl) !== "" && !d2Failed) ? vItem.secondaryUrl : vItem.url;
                } else { // Auto (0)
                    if ((root.size.width > 1 || root.size.height > 1) && !viewportItem.fullScreen && String(vItem.secondaryUrl) !== "" && !d2Failed) {
                        return vItem.secondaryUrl;
                    }
                    return vItem.url;
                }
            });

            player.streamIndex = Qt.binding(function() {
                if (player.isOneToOne) {
                    return 1;
                }
                var vItem = root.model.get(index);
                if (!vItem) return 1;
                var d2Failed = viewportItem.d2SecondaryUrlFailed;
                var isHik = String(vItem.url).indexOf("hikvision://") === 0;
                if (vItem.streamMode === 1) {
                    return 1;
                } else if (vItem.streamMode === 3) {
                    return 3;
                } else if (vItem.streamMode === 2) {
                    return (isHik || (String(vItem.secondaryUrl) !== "" && !d2Failed)) ? 2 : 1;
                } else { // Auto (0)
                    return ((root.size.width > 1 || root.size.height > 1) && !viewportItem.fullScreen && (isHik || (String(vItem.secondaryUrl) !== "" && !d2Failed))) ? 2 : 1;
                }
            });
            player.isSubStream = Qt.binding(function() { return player.streamIndex === 2; });

            player.scale = Qt.binding(function() {
                return viewportItem.zoomEnabled ? viewportItem.zoomScale : 1.0;
            });
            player.transformOrigin = Item.TopLeft;
            player.x = Qt.binding(function() {
                return viewportItem.zoomEnabled ? viewportItem.panX : 0;
            });
            player.y = Qt.binding(function() {
                return viewportItem.zoomEnabled ? viewportItem.panY : 0;
            });

            player.width = Qt.binding(function() { return parentContainer.width; });
            player.height = Qt.binding(function() { return parentContainer.height; });
            player.loops = MediaPlayer.Infinite;
            player.isFullScreen = Qt.binding(function() { return root.fullScreenIndex === index; });
            player.tightenOnDrag = Qt.binding(function() {
                return viewportItem.fullScreen || (root.size.width === 1 && root.size.height === 1);
            });
            player.layoutModel = root.model;

            // Connect mediaError signal
            var slot = function(errorSource) {
                var vItem = root.model.get(index);
                if (vItem && vItem.streamMode !== 3 && errorSource === String(vItem.secondaryUrl)) {
                    viewportItem.d2SecondaryUrlFailed = true;
                }
            };
            player.mediaError.connect(slot);
            mediaErrorSlotsMap[index] = slot;

            activePlayersMap[index] = player;
            return player;
        }

        function releasePlayer(index) {
            var player = activePlayersMap[index];
            if (player) {
                player.parent = null;
                try {
                    var slot = mediaErrorSlotsMap[index];
                    if (slot) {
                        player.mediaError.disconnect(slot);
                    }
                } catch(e) {}
                delete mediaErrorSlotsMap[index];
                
                // Clear bindings so they don't capture parentContainer and viewportItem anymore!
                player.visible = false;
                player.index = -1;
                player.color = "black";
                player.volume = 0;
                player.avOptions = ({});
                player.source = "";
                player.isSubStream = false;
                player.scale = 1.0;
                player.x = 0;
                player.y = 0;
                player.width = 0;
                player.height = 0;

                // Drop the player with the cell. A pool kept every retired picture's
                // decoders alive for as long as the layout stayed on screen.
                player.destroy();
                delete activePlayersMap[index];
            }
        }

        function releaseAll() {
            var indices = Object.keys(activePlayersMap);
            for (var i = 0; i < indices.length; i++) {
                releasePlayer(indices[i]);
            }
        }
    }

    // While one camera fills the layout, move to the next or previous camera in this layout
    // and keep it maximized. Empty cells and cells covered by a merge are skipped. Wraps around.
    function stepMaximizedCamera(direction) {
        if (!direction || d.fullScreenIndex < 0 || !model)
            return false;
        var count = model.count;
        if (count < 1)
            return false;
        var start = d.fullScreenIndex;
        for (var step = 1; step <= count; ++step) {
            var idx = (start + direction * step) % count;
            if (idx < 0)
                idx += count;
            var item = model.get(idx);
            if (!item || item.visible !== ViewportsLayoutItem.Visible)
                continue;
            if (String(item.url || "") === "")
                continue;
            var cell = root.get(idx);
            if (!cell)
                continue;
            var previous = root.get(start);
            if (previous && previous !== cell)
                previous.fullScreen = false;
            d.fullScreenIndex = idx;
            cell.fullScreen = true;
            cell.forceActiveFocus();
            return true;
        }
        return false;
    }

    readonly property alias fullScreenIndex: d.fullScreenIndex
    readonly property alias focusIndex: d.focusIndex
    readonly property alias activeFocusIndex: d.activeFocusIndex
    readonly property alias pressAndHoldIndex: d.pressAndHoldIndex
    readonly property alias multiselect: d.multiselect

    onVisibleChanged: {
        d.selectionReset()
        if (!visible)
            playerPool.releaseAll();
    }

    QtObject {
        id: d

        property real layoutRatio: (model.aspectRatio.width * model.size.width) / (model.aspectRatio.height * model.size.height);
        property int fullScreenIndex: -1
        property int focusIndex: -1
        property int activeFocusIndex: -1
        property int pressAndHoldIndex: -1
        // The two corners of the selection. They stay put when focus leaves the grid
        // (the Merge button) and when a camera is dragged to another tile.
        property int selectionIndex1: -1
        property int selectionIndex2: -1
        property bool selectionActive: false
        property bool selectionRefreshHold: false
        property int selLeft: 0
        property int selTop: 0
        property int selRight: 0
        property int selBottom: 0
        property bool multiselect: selectionActive && ((selRight - selLeft) > 1 || (selBottom - selTop) > 1)
        property int keyModifiers: 0
        property int dragSourceIndex: -1
        property int dragTargetIndex: -1
        property real dragStartX: 0
        property real dragStartY: 0
        property bool isDragging: false
        property bool dragSelects: false
        property string swapInProgressKey: ""

        function swapViewportItems(sourceIndex, targetIndex) {
            if (sourceIndex === targetIndex || sourceIndex < 0 || targetIndex < 0)
                return false;
            if (sourceIndex >= root.model.count || targetIndex >= root.model.count)
                return false;

            var key = Math.min(sourceIndex, targetIndex) + ":" + Math.max(sourceIndex, targetIndex);
            if (swapInProgressKey === key)
                return false;
            swapInProgressKey = key;

            var sourceItem = root.model.get(sourceIndex);
            var targetItem = root.model.get(targetIndex);
            if (!sourceItem || !targetItem) {
                swapInProgressKey = "";
                return false;
            }

            var sourcePlayer = playerPool.activePlayersMap[sourceIndex];
            var targetPlayer = playerPool.activePlayersMap[targetIndex];
            if (sourcePlayer && sourcePlayer.prepareForSwap)
                sourcePlayer.prepareForSwap();
            if (targetPlayer && targetPlayer.prepareForSwap)
                targetPlayer.prepareForSwap();

            var tempUrl = sourceItem.url;
            var tempSecUrl = sourceItem.secondaryUrl;
            var tempVol = sourceItem.volume;
            var tempOpts = sourceItem.avFormatOptions;
            var tempStreamMode = sourceItem.streamMode;

            sourceItem.url = targetItem.url;
            sourceItem.secondaryUrl = targetItem.secondaryUrl;
            sourceItem.volume = targetItem.volume;
            sourceItem.avFormatOptions = targetItem.avFormatOptions;
            sourceItem.streamMode = targetItem.streamMode;

            targetItem.url = tempUrl;
            targetItem.secondaryUrl = tempSecUrl;
            targetItem.volume = tempVol;
            targetItem.avFormatOptions = tempOpts;
            targetItem.streamMode = tempStreamMode;

            Utils.log_info("Swapped viewport " + (sourceIndex + 1) + " with " + (targetIndex + 1));
            Qt.callLater(function() { d.swapInProgressKey = ""; });
            return true;
        }

        onLayoutRatioChanged: selectionReset()
        onSelectionIndex1Changed: if (!selectionRefreshHold) refreshSelection()
        onSelectionIndex2Changed: if (!selectionRefreshHold) refreshSelection()

        function columnFromIndex(index) {
            return index % root.size.width;
        }

        function rowFromIndex(index) {
            return Math.floor(index / root.size.width);
        }

        function indexFromAddress(column, row) {
            return row * root.size.width + column;
        }

        // A covered slot stores the negative step back to the tile that hides it.
        function anchorIndex(index) {
            if (!root.model || index < 0 || index >= root.model.count)
                return -1;
            var item = root.model.get(index);
            if (!item)
                return -1;
            if (item.visible === ViewportsLayoutItem.Visible)
                return index;
            var col = columnFromIndex(index) + item.columnSpan;
            var row = rowFromIndex(index) + item.rowSpan;
            if (col < 0 || row < 0 || col >= root.size.width || row >= root.size.height)
                return -1;
            var resolved = indexFromAddress(col, row);
            var anchor = root.model.get(resolved);
            if (!anchor || anchor.visible !== ViewportsLayoutItem.Visible)
                return -1;
            return resolved;
        }

        // The block the highlight and the Merge button share. It starts as the rectangle
        // between the two corners, then grows to take in any joined tile it touches.
        function refreshSelection() {
            var left = 0;
            var top = 0;
            var right = 0;
            var bottom = 0;
            var active = false;
            if (root.model && root.size && root.size.width >= 1 && root.size.height >= 1) {
                var a = anchorIndex(selectionIndex1);
                var b = anchorIndex(selectionIndex2);
                if (a >= 0 && b >= 0) {
                    left = Math.min(columnFromIndex(a), columnFromIndex(b));
                    right = Math.max(columnFromIndex(a), columnFromIndex(b)) + 1;
                    top = Math.min(rowFromIndex(a), rowFromIndex(b));
                    bottom = Math.max(rowFromIndex(a), rowFromIndex(b)) + 1;
                    var guard = root.size.width * root.size.height;
                    var grew = true;
                    while (grew && guard-- > 0) {
                        grew = false;
                        for (var i = 0; i < root.model.count; ++i) {
                            var tile = root.model.get(i);
                            if (!tile || tile.visible !== ViewportsLayoutItem.Visible)
                                continue;
                            var spanW = Math.max(tile.columnSpan, 1);
                            var spanH = Math.max(tile.rowSpan, 1);
                            if (spanW === 1 && spanH === 1)
                                continue;
                            var c = columnFromIndex(i);
                            var r = rowFromIndex(i);
                            if ((c + spanW) <= left || c >= right || (r + spanH) <= top || r >= bottom)
                                continue;
                            if (c < left) { left = c; grew = true; }
                            if (c + spanW > right) { right = c + spanW; grew = true; }
                            if (r < top) { top = r; grew = true; }
                            if (r + spanH > bottom) { bottom = r + spanH; grew = true; }
                        }
                    }
                    active = true;
                }
            }
            selLeft = left;
            selTop = top;
            selRight = right;
            selBottom = bottom;
            selectionActive = active;
        }

        function selectionTop() { return selTop; }
        function selectionRight() { return selRight; }
        function selectionBottom() { return selBottom; }
        function selectionLeft() { return selLeft; }
        function selectionWidth() { return selectionActive ? selRight - selLeft : 0; }
        function selectionHeight() { return selectionActive ? selBottom - selTop : 0; }

        function selectionContains(index) {
            if (!selectionActive)
                return false;
            var item = root.model.get(index);
            if (!item || item.visible !== ViewportsLayoutItem.Visible)
                return false;
            var column = columnFromIndex(index);
            var row = rowFromIndex(index);
            var spanW = Math.max(item.columnSpan, 1);
            var spanH = Math.max(item.rowSpan, 1);
            return column < selRight && (column + spanW) > selLeft
                    && row < selBottom && (row + spanH) > selTop;
        }

        function setSelectionAnchor(index) {
            if (index < 0)
                return;
            selectionRefreshHold = true;
            if (selectionIndex1 !== index)
                selectionIndex1 = index;
            if (selectionIndex2 !== index)
                selectionIndex2 = index;
            selectionRefreshHold = false;
            refreshSelection();
        }

        function extendSelection(index) {
            if (index < 0)
                return;
            selectionRefreshHold = true;
            if (selectionIndex1 < 0)
                selectionIndex1 = index;
            if (selectionIndex2 !== index)
                selectionIndex2 = index;
            selectionRefreshHold = false;
            refreshSelection();
        }

        function selectionReset() {
            selectionRefreshHold = true;
            if (selectionIndex1 < 0) {
                if (selectionIndex2 !== -1)
                    selectionIndex2 = -1;
            } else if (selectionIndex2 !== selectionIndex1) {
                selectionIndex2 = selectionIndex1;
            }
            selectionRefreshHold = false;
            refreshSelection();
        }
    }

    Rectangle {
        color: root.color
        anchors.fill: parent
    }

    GridLayout {
        id: layout

        width: (root.width / root.height <= d.layoutRatio) ? root.width : root.height * d.layoutRatio;
        height: (root.width / root.height < d.layoutRatio) ? root.width / d.layoutRatio : root.height;
        columns: root.size.width
        rows: root.size.height
        columnSpacing: 0
        rowSpacing: 0
        anchors.centerIn: parent

        Repeater {
            id: repeater

            model: root.visible ? root.model : null

            onCountChanged: {
                if (d.fullScreenIndex >= count) {
                    d.fullScreenIndex = -1;
                }
                if (d.focusIndex) {
                    if (count == 1) {
                        d.focusIndex = 0;
                    } else {
                        d.focusIndex = -1;
                    }
                }
                if (d.activeFocusIndex) {
                    d.activeFocusIndex = -1;
                }
                if (d.pressAndHoldIndex) {
                    d.pressAndHoldIndex = -1;
                }
            }

            // Covered slots stay unloaded. A Player for every slot of a merged grid stalls the window.
            delegate: Loader {
                id: cellLoader

                active: root.visible && ((model.visible === ViewportsLayoutItem.Visible) ? true : false)
                visible: active
                asynchronous: false

                function maximizeCell() {
                    if (item)
                        item.maximizeCell();
                }

                Layout.fillHeight: false
                Layout.fillWidth: false
                Layout.preferredWidth: (layout.width / root.size.width) * Math.max(model.columnSpan, 1)
                Layout.preferredHeight: (layout.height / root.size.height) * Math.max(model.rowSpan, 1)
                Layout.minimumWidth: Layout.preferredWidth
                Layout.minimumHeight: Layout.preferredHeight
                Layout.maximumWidth: Layout.preferredWidth
                Layout.maximumHeight: Layout.preferredHeight
                Layout.columnSpan: Math.max(model.columnSpan, 1)
                Layout.rowSpan: Math.max(model.rowSpan, 1)

                sourceComponent: Component {
                Item {
                    id: container
                    // The picture is moved onto the layout while maximized, so it is no longer
                    // container.children[0]. This reference still finds it.
                    property var viewportItem: viewport

                    implicitWidth: (layout.width / root.size.width) * Math.max(viewport.columnSpan, 0)
                    implicitHeight: (layout.height / root.size.height) * Math.max(viewport.rowSpan, 0)

                    function maximizeCell() {
                        viewport.forceActiveFocus();
                        viewport.fullScreen = true;
                        d.selectionReset();
                    }

                Item {
                    id: viewport

                    x: 0
                    y: 0
                    width: parent.width
                    height: parent.height
                    activeFocusOnTab: d.fullScreenIndex < 0 || d.fullScreenIndex === model.index

                    property int cursorColumnOffset: 0
                    property int cursorRowOffset: 0
                    property bool fullScreen: false
                    readonly property bool dragActive: d.isDragging && d.dragSourceIndex === model.index

                    property var player: null
                    property alias d2SecondaryUrlFailed: d2.secondaryUrlFailed
                    property string cellUrl: model && model.url ? model.url : ""
                    property bool cellReady: false

                    function ensurePlayer() {
                        if (!cellReady)
                            return;
                        if (cellUrl !== "" && !player)
                            player = playerPool.acquirePlayer(model.index, playerContainer, viewport);
                        else if (cellUrl === "" && player) {
                            playerPool.releasePlayer(model.index);
                            player = null;
                        }
                    }

                    onCellUrlChanged: ensurePlayer()
                    Component.onCompleted: {
                        cellReady = true;
                        ensurePlayer();
                    }
                    Component.onDestruction: {
                        playerPool.releasePlayer(model.index);
                    }
                    
                    // Zoom properties
                    property real zoomScale: 1.0
                    property real panX: 0
                    property real panY: 0
                    readonly property bool zoomEnabled: fullScreen || (root.size.width === 1 && root.size.height === 1)

                    // Wheel zoom of the picture that already fills this cell. The point stays under the cursor.
                    function zoomByWheelAt(localX, localY, angleDeltaY) {
                        if (!zoomEnabled)
                            return false;
                        var delta = angleDeltaY / 120;
                        if (delta === 0)
                            return false;
                        var newScale = Number(zoomScale * (1 + delta * 0.1)).clamp(1.0, 10.0);
                        if (newScale === zoomScale)
                            return true;
                        var imageX = (localX - panX) / zoomScale;
                        var imageY = (localY - panY) / zoomScale;
                        zoomScale = newScale;
                        panX = Number(localX - imageX * newScale).clamp(width - width * newScale, 0);
                        panY = Number(localY - imageY * newScale).clamp(height - height * newScale, 0);
                        return true;
                    }

                    readonly property alias selected: d2.selected

                    readonly property alias url: d2.url
                    readonly property alias secondaryUrl: d2.secondaryUrl
                    readonly property alias column: d2.column
                    readonly property alias row: d2.row
                    readonly property alias columnSpan: d2.columnSpan
                    readonly property alias rowSpan: d2.rowSpan
                    readonly property alias volume: d2.volume
                    readonly property alias avFormatOptions: d2.avFormatOptions
                    readonly property alias streamMode: d2.streamMode

                    readonly property alias topIndex: d2.topIndex
                    readonly property alias rightIndex: d2.rightIndex
                    readonly property alias bottomIndex: d2.bottomIndex
                    readonly property alias leftIndex: d2.leftIndex

                    readonly property bool hasAudio: player ? player.hasAudio : false
                    // The level M restores. Full volume is only the fallback when this tile has never been turned up.
                    property real audibleVolume: 1

                    // The cell stays cell-sized. While maximized, this item is moved onto the layout
                    // itself so the picture, its buttons, and a drag all belong to this camera.
                    // A child drawn bigger than its cell never receives those clicks: every ancestor
                    // has to contain the point.
                    function placeForFullScreen() {
                        if (fullScreen) {
                            parent = root;
                            z = 100;
                            x = Qt.binding(function() { return layout.x; });
                            y = Qt.binding(function() { return layout.y; });
                            width = Qt.binding(function() { return layout.width; });
                            height = Qt.binding(function() { return layout.height; });
                        } else {
                            z = 0;
                            parent = container;
                            x = 0;
                            y = 0;
                            width = Qt.binding(function() { return container.width; });
                            height = Qt.binding(function() { return container.height; });
                        }
                    }

                    onVisibleChanged: {
                        fullScreen = false;
                        resetZoom();
                    }
                    property real preFullScreenVolume: 0.0

                    onFullScreenChanged: {
                        placeForFullScreen();
                        if (fullScreen)
                            forceActiveFocus();
                        d2.setCurrentIndex("fullScreenIndex", fullScreen)
                        var vItem = root.model.get(model.index);
                        if (vItem) {
                            if (fullScreen) {
                                preFullScreenVolume = vItem.volume;
                                if (!viewportSettings.noUnmuteWhenFullScreen && vItem.volume <= 0.0) {
                                    vItem.volume = 0.25;
                                }
                            } else {
                                resetZoom();
                                if (!viewportSettings.noUnmuteWhenFullScreen) {
                                    vItem.volume = preFullScreenVolume;
                                }
                            }
                        } else if (!fullScreen) {
                            resetZoom();
                        }
                    }
                    onZoomEnabledChanged: {
                        if (!zoomEnabled) {
                            resetZoom();
                        }
                    }
                    onFocusChanged: {
                        d2.setCurrentIndex("focusIndex", focus);
                        d2.setCurrentIndex("pressAndHoldIndex", false);
                        // Leaving focus must not close this camera. Opening the next one, and moving
                        // this picture onto the layout, both drop focus for a moment. Double-click
                        // and Escape still leave the single-camera view.
                    }
                    onActiveFocusChanged: d2.setCurrentIndex("activeFocusIndex", activeFocus)
                    onSelectedChanged: {
                        if (!selected) {
                            cursorColumnOffset = 0;
                            cursorRowOffset = 0;
                        }
                    }

                    function resetZoom() {
                        zoomScale = 1.0;
                        panX = 0;
                        panY = 0;
                    }

                    Keys.onPressed: {
                        var fullScreenKey = QT_TR_NOOP("F", "Shortcut");
                        if (event.text.toUpperCase() === fullScreenKey ||
                            event.text.toUpperCase() === qsTr(fullScreenKey)) {
                            fullScreen = (root.size.width > 1 && root.size.height > 1) ? !fullScreen : false;
                            d.selectionReset();
                        }

                        function keyNavigationHandler(keyNavigationCallback) {
                            if (fullScreen)
                                return;
                            // The arrow event itself carries Shift. The layout's modifier flag does not:
                            // this tile handles the key first.
                            if (event.modifiers & Qt.ShiftModifier) {
                                var from = d.anchorIndex(d.selectionIndex2);
                                if (from < 0)
                                    from = model.index;
                                d.extendSelection(keyNavigationCallback(from));
                            } else {
                                var nextIndex = keyNavigationCallback(model.index);
                                var nextCell = root.get(nextIndex);
                                if (nextCell)
                                    nextCell.forceActiveFocus();
                                d.setSelectionAnchor(nextIndex);
                            }
                        }

                        switch (event.key) {
                        case Qt.Key_Escape:
                            focus = false;
                            fullScreen = false;
                            break;
                        case Qt.Key_Up:
                            function keyUpCallback(index) {
                                var origin = root.get(index);
                                if (!origin)
                                    return index;
                                var topIndex = origin.topIndex;

                                if (topIndex !== index) {
                                    var dest = root.get(topIndex);
                                    if (dest)
                                        dest.cursorColumnOffset =
                                            d.columnFromIndex(index) + origin.cursorColumnOffset - d.columnFromIndex(topIndex);
                                } else {
                                    origin.cursorRowOffset = Math.max(origin.cursorRowOffset - 1, 0);
                                }

                                return topIndex;
                            }

                            keyNavigationHandler(keyUpCallback);
                            break;
                        case Qt.Key_Down:
                            function keyDownCallback(index) {
                                var origin = root.get(index);
                                if (!origin)
                                    return index;
                                var bottomIndex = origin.bottomIndex;

                                if (bottomIndex !== index) {
                                    var dest = root.get(bottomIndex);
                                    if (dest)
                                        dest.cursorColumnOffset =
                                            d.columnFromIndex(index) + origin.cursorColumnOffset - d.columnFromIndex(bottomIndex);
                                } else {
                                    origin.cursorRowOffset = Math.min(origin.cursorRowOffset + 1, origin.rowSpan - 1);
                                }

                                return bottomIndex;
                            }

                            keyNavigationHandler(keyDownCallback);
                            break;
                        case Qt.Key_Right:
                            function keyRightCallback(index) {
                                var origin = root.get(index);
                                if (!origin)
                                    return index;
                                var rightIndex = origin.rightIndex;

                                if (rightIndex !== index) {
                                    var dest = root.get(rightIndex);
                                    if (dest)
                                        dest.cursorRowOffset =
                                            d.rowFromIndex(index) + origin.cursorRowOffset - d.rowFromIndex(rightIndex);
                                } else {
                                    origin.cursorColumnOffset = Math.min(origin.cursorColumnOffset + 1, origin.columnSpan - 1);
                                }

                                return rightIndex;
                            }

                            keyNavigationHandler(keyRightCallback);
                            break;
                        case Qt.Key_Left:
                            function keyLeftCallback(index) {
                                var origin = root.get(index);
                                if (!origin)
                                    return index;
                                var leftIndex = origin.leftIndex;

                                if (leftIndex !== index) {
                                    var dest = root.get(leftIndex);
                                    if (dest)
                                        dest.cursorRowOffset =
                                            d.rowFromIndex(index) + origin.cursorRowOffset - d.rowFromIndex(leftIndex);
                                } else {
                                    origin.cursorColumnOffset = Math.max(origin.cursorColumnOffset - 1, 0);
                                }

                                return leftIndex;
                            }

                            keyNavigationHandler(keyLeftCallback);
                            break;
                        case Qt.Key_Plus:
                        case Qt.Key_Equal:
                            if (event.text === "+" || event.key === Qt.Key_Plus) {
                                if (viewport.player && viewport.player.recorderIp !== "") {
                                     if (!event.isAutoRepeat) {
                                         HikvisionManager.ptzZoom(viewport.player.recorderIp, viewport.player.recorderPort, viewport.player.username, viewport.player.password, viewport.player.channelId, 11, false);
                                     }
                                     event.accepted = true;
                                 }
                            }
                            break;
                        case Qt.Key_Minus:
                            if (event.text === "-" || event.key === Qt.Key_Minus) {
                                if (viewport.player && viewport.player.recorderIp !== "") {
                                     if (!event.isAutoRepeat) {
                                         HikvisionManager.ptzZoom(viewport.player.recorderIp, viewport.player.recorderPort, viewport.player.username, viewport.player.password, viewport.player.channelId, 12, false);
                                     }
                                     event.accepted = true;
                                 }
                            }
                            break;
                        }
                    }

                    Keys.onReleased: {
                        if (event.isAutoRepeat) {
                            return;
                        }
                        if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal || event.text === "+") {
                            if (viewport.player && viewport.player.recorderIp !== "") {
                                HikvisionManager.ptzZoom(viewport.player.recorderIp, viewport.player.recorderPort, viewport.player.username, viewport.player.password, viewport.player.channelId, 11, true);
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Minus || event.text === "-") {
                            if (viewport.player && viewport.player.recorderIp !== "") {
                                HikvisionManager.ptzZoom(viewport.player.recorderIp, viewport.player.recorderPort, viewport.player.username, viewport.player.password, viewport.player.channelId, 12, true);
                                event.accepted = true;
                            }
                        }
                    }

                    QtObject {
                        id: d2

                        property bool selected: d.selectionContains(model.index)

                        property string url: model && model.url ? model.url : ""
                        property string secondaryUrl: model && model.secondaryUrl ? model.secondaryUrl : ""
                        property bool secondaryUrlFailed: false
                        property int column: d.columnFromIndex(model.index)
                        property int row: d.rowFromIndex(model.index)
                        property int columnSpan: model && model.columnSpan !== undefined ? model.columnSpan : 1
                        property int rowSpan: model && model.rowSpan !== undefined ? model.rowSpan : 1
                        property real volume: model && model.volume !== undefined ? model.volume : 0
                        property var avFormatOptions: model ? model.avFormatOptions : ({})
                        property int streamMode: model && model.streamMode !== undefined ? model.streamMode : 0

                        onSecondaryUrlChanged: secondaryUrlFailed = false

                        property int topIndex: spanningIndex(viewport.column + viewport.cursorColumnOffset,
                                                             Number(viewport.row - 1).clamp(0, root.size.height - 1))

                        property int bottomIndex: spanningIndex(viewport.column + viewport.cursorColumnOffset,
                                                                Number(viewport.row + viewport.rowSpan).clamp(0, root.size.height - 1))

                        property int rightIndex: spanningIndex(Utils.ifLeftToRight(
                                                               Number(viewport.column + viewport.columnSpan).clamp(0, root.size.width - 1),
                                                               Number(viewport.column - 1).clamp(0, root.size.width - 1)),
                                                               viewport.row + viewport.cursorRowOffset)

                        property int leftIndex: spanningIndex(Utils.ifLeftToRight(
                                                              Number(viewport.column - 1).clamp(0, root.size.width - 1),
                                                              Number(viewport.column + viewport.columnSpan).clamp(0, root.size.width - 1)),
                                                              viewport.row + viewport.cursorRowOffset)

                        function setCurrentIndex(key, current) {
                            if (current === true) {
                                d[key] = model.index;
                            } else if (d[key] === model.index) {
                                d[key] = -1;
                            }
                        }

                        function spanningIndex(column, row) {
                            var idx = d.indexFromAddress(column, row);

                            if (idx !== model.index) {
                                // Covered cells are not built. Their columnSpan/rowSpan are the
                                // negative offset back to the anchor cell that covers them.
                                var cell = root.model.get(idx);
                                if (cell && cell.visible !== ViewportsLayoutItem.Visible) {
                                    idx = d.indexFromAddress(d.columnFromIndex(idx) + cell.columnSpan,
                                                             d.rowFromIndex(idx) + cell.rowSpan);
                                }
                            }

                            return idx;
                        }
                    }

                    Rectangle {
                        id: playerContainer

                        color: root.color
                        anchors.fill: parent
                        clip: true
                        opacity: viewport.dragActive ? 0.5 : 1.0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                    }

                    Rectangle {
                        id: emptyViewportBorder
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: "#182026"
                        visible: model.url === ""
                    }

                    Rectangle {
                        id: selectionRect

                        color: "transparent"
                        anchors.fill: parent

                        states: [
                            State {
                                name: "multiselect"
                                when: root.multiselect && viewport.selected

                                PropertyChanges {
                                    target: selectionRect
                                    color: "#4000a8ff"
                                }
                            }
                        ]
                    }

                    Rectangle {
                        id: selectionFrame

                        color: "transparent"
                        border.color: "transparent"
                        anchors.fill: parent

                        states: [
                            State {
                                name: "active"
                                when: viewport.activeFocus && !Context.config.kioskMode

                                PropertyChanges {
                                    target: selectionFrame
                                    border.width: 1
                                    border.color: "#00dd00"
                                }
                            },
                            State {
                                name: "swapSource"
                                when: root.pendingSwapSourceIndex === model.index

                                PropertyChanges {
                                    target: selectionFrame
                                    border.width: 2
                                    border.color: "#00f5d4"
                                }
                            },
                            State {
                                name: "dragSource"
                                when: d.isDragging && d.dragSourceIndex === model.index

                                PropertyChanges {
                                    target: selectionFrame
                                    border.width: 3
                                    border.color: "#ff7a00"
                                }
                            },
                            State {
                                name: "dragTarget"
                                when: d.isDragging && d.dragTargetIndex === model.index

                                PropertyChanges {
                                    target: selectionFrame
                                    border.width: 3
                                    border.color: "#00f5d4"
                                }
                            }
                        ]
                    }

                    Item {
                        id: dragDummyViewport
                        width: 1; height: 1
                        visible: false
                    }
                    MouseArea {
                        id: viewportMouseArea
                        z: -1
                        anchors.fill: parent

                        // Enable wheel events for zooming, and middle-button drag for panning
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        hoverEnabled: true
                        property bool panning: false
                        property real panLastX: 0
                        property real panLastY: 0
                        cursorShape: panning ? Qt.ClosedHandCursor
                                             : (d.isDragging ? Qt.DragMoveCursor
                                                             : (root.pendingSwapSourceIndex >= 0 ? Qt.DragMoveCursor : Qt.ArrowCursor))

                        function clampPan() {
                            var scale = viewport.zoomScale;
                            viewport.panX = Number(viewport.panX).clamp(viewport.width - viewport.width * scale, 0);
                            viewport.panY = Number(viewport.panY).clamp(viewport.height - viewport.height * scale, 0);
                        }

                        onPressed: {
                            if (mouse.button === Qt.MiddleButton) {
                                if (viewport.zoomEnabled && viewport.zoomScale > 1.0) {
                                    panning = true;
                                    panLastX = mouse.x;
                                    panLastY = mouse.y;
                                    mouse.accepted = true;
                                }
                                return;
                            }
                            if (mouse.button === Qt.RightButton) {
                                if (generalSettings.enableContextMenu) {
                                    root.pendingSwapSourceIndex = -1;
                                    root.popupFitted(contextMenu, null, 0, 0);
                                }
                                return;
                            }
                            // While the Add camera window is open, a click picks the cell it fills next
                            if (addCameraDialog.visible && addCameraDialog.layoutModel === root.model) {
                                addCameraDialog.targetIndex = model.index;
                            }
                            // This picture covers the layout. A drag on it must not swap in another camera.
                            if (viewport.fullScreen) {
                                d.dragSourceIndex = -1;
                                d.dragSelects = false;
                                d.isDragging = false;
                                viewport.forceActiveFocus();
                                return;
                            }
                            // Left button: record potential drag start in root coordinates.
                            // Shift or Ctrl chooses tiles. A plain drag swaps cameras and leaves the selection.
                            var pt = viewportMouseArea.mapToItem(root, mouse.x, mouse.y);
                            d.dragSourceIndex = model.index;
                            d.dragStartX = pt.x;
                            d.dragStartY = pt.y;
                            d.isDragging = false;
                            d.dragTargetIndex = -1;
                            d.dragSelects = (mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) !== 0;
                            if (d.dragSelects)
                                d.extendSelection(model.index);
                        }
                        onPositionChanged: {
                            if (panning) {
                                viewport.panX += mouse.x - panLastX;
                                viewport.panY += mouse.y - panLastY;
                                panLastX = mouse.x;
                                panLastY = mouse.y;
                                clampPan();
                                return;
                            }
                            if (viewport.fullScreen)
                                return;
                            if (d.dragSelects && d.dragSourceIndex >= 0) {
                                var selectPt = viewportMouseArea.mapToItem(root, mouse.x, mouse.y);
                                var under = root.indexAt(selectPt.x, selectPt.y);
                                if (under >= 0)
                                    d.extendSelection(under);
                                return;
                            }
                            if (d.dragSourceIndex >= 0 && !d.isDragging) {
                                var pt = viewportMouseArea.mapToItem(root, mouse.x, mouse.y);
                                var dx = Math.abs(pt.x - d.dragStartX);
                                var dy = Math.abs(pt.y - d.dragStartY);
                                if (dx > 15 || dy > 15) {
                                    d.isDragging = true;
                                    d.dragTargetIndex = root.indexAt(pt.x, pt.y);
                                }
                            }
                        }
                        onReleased: {
                            if (mouse.button === Qt.MiddleButton || panning) {
                                panning = false;
                                return;
                            }
                            var pt = viewportMouseArea.mapToItem(root, mouse.x, mouse.y);
                            var targetIndex = root.indexAt(pt.x, pt.y);

                            if (d.dragSelects && d.dragSourceIndex >= 0) {
                                if (targetIndex >= 0)
                                    d.extendSelection(targetIndex);
                            } else if (d.dragSourceIndex >= 0 && targetIndex >= 0 && targetIndex !== d.dragSourceIndex) {
                                var dx = Math.abs(pt.x - d.dragStartX);
                                var dy = Math.abs(pt.y - d.dragStartY);
                                if ((dx > 15 || dy > 15) && generalSettings.allowSwappingViewports) {
                                    d.swapViewportItems(d.dragSourceIndex, targetIndex);
                                }
                            } else if (!d.isDragging && d.dragSourceIndex >= 0) {
                                // Normal click behavior (no drag occurred)
                                var clickTargetIndex = model.index;
                                if (root.pendingSwapSourceIndex >= 0 && generalSettings.allowSwappingViewports) {
                                    var sourceIndex = root.pendingSwapSourceIndex;
                                    if (sourceIndex !== clickTargetIndex) {
                                        d.swapViewportItems(sourceIndex, clickTargetIndex);
                                    }
                                    root.pendingSwapSourceIndex = -1;
                                } else if (mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) {
                                    d.extendSelection(clickTargetIndex);
                                } else {
                                    viewport.forceActiveFocus();
                                    d.setSelectionAnchor(clickTargetIndex);
                                }
                            }
                            d.dragSourceIndex = -1;
                            d.dragTargetIndex = -1;
                            d.isDragging = false;
                            d.dragSelects = false;
                        }
                        onPressAndHold: d2.setCurrentIndex("pressAndHoldIndex", true)
                        onDoubleClicked: {
                            viewport.fullScreen = (root.size.width > 1 && root.size.height > 1) ? !viewport.fullScreen : false;
                            d.selectionReset();
                        }

                        // Handle mousewheel zoom when in fullscreen (requires CTRL modifier)
                        onWheel: {
                            // A maximized camera's wheel moves to the next camera. Only a tile that is
                            // still in the grid uses the wheel to tighten a box zoom.
                            if (viewport.player && viewport.player.isZoomed && !viewport.fullScreen &&
                                !(wheel.modifiers & (Qt.AltModifier | Qt.MetaModifier)) &&
                                !((wheel.modifiers & Qt.ControlModifier) && wheel.angleDelta.y < 0 && viewport.zoomScale > 1.0)) {
                                var pp = viewport.player.mapFromItem(viewportMouseArea, wheel.x, wheel.y);
                                viewport.player.zoomByWheel(wheel.angleDelta.y, pp.x, pp.y);
                                wheel.accepted = true;
                            } else if (wheel.modifiers & Qt.ControlModifier) {
                                if (!viewport.fullScreen && root.size.width > 1 && root.size.height > 1) {
                                    viewport.fullScreen = true;
                                    viewport.forceActiveFocus();
                                    d.selectionReset();
                                }

                                if (viewport.zoomEnabled) {
                                    var delta = wheel.angleDelta.y / 120;
                                    var zoomFactor = 1 + (delta * 0.1);

                                    var newScale = viewport.zoomScale * zoomFactor;
                                    newScale = Number(newScale).clamp(1.0, 10.0);

                                    if (newScale !== viewport.zoomScale) {
                                        var mouseX = wheel.x;
                                        var mouseY = wheel.y;

                                        var imageX = (mouseX - viewport.panX) / viewport.zoomScale;
                                        var imageY = (mouseY - viewport.panY) / viewport.zoomScale;

                                        viewport.zoomScale = newScale;

                                        viewport.panX = mouseX - imageX * newScale;
                                        viewport.panY = mouseY - imageY * newScale;

                                        var minPanX = viewport.width - (viewport.width * newScale);
                                        var maxPanX = 0;
                                        var minPanY = viewport.height - (viewport.height * newScale);
                                        var maxPanY = 0;

                                        viewport.panX = Number(viewport.panX).clamp(minPanX, maxPanX);
                                        viewport.panY = Number(viewport.panY).clamp(minPanY, maxPanY);
                                    }
                                }

                                wheel.accepted = true;
                            } else if (root.fullScreenIndex >= 0 &&
                                       !(wheel.modifiers & (Qt.AltModifier | Qt.MetaModifier))) {
                                // Covered cells sit under the maximized picture. A wheel there still
                                // changes that camera, rather than switching to another layout.
                                var stepDelta = wheel.angleDelta.y;
                                if (stepDelta === 0 && wheel.pixelDelta)
                                    stepDelta = wheel.pixelDelta.y;
                                if (stepDelta === 0)
                                    stepDelta = wheel.angleDelta.x;
                                if (stepDelta !== 0 && rootWindow.wheelStepAllowed())
                                    root.stepMaximizedCamera(stepDelta > 0 ? 1 : -1);
                                wheel.accepted = true;
                            } else if (!(wheel.modifiers & (Qt.AltModifier | Qt.MetaModifier)) &&
                                       !viewport.fullScreen &&
                                       !(root.size.width === 1 && root.size.height === 1)) {
                                var host = rootWindow.activeLayoutWindow ? rootWindow.activeLayoutWindow : rootWindow;
                                var collection = (host === rootWindow) ? layoutsCollectionModel : host.layoutsModel;
                                var current = (host === rootWindow) ? stackLayout.currentIndex : host.layoutIndex;
                                rootWindow.handleLayoutWheel(wheel, collection, current, function(idx) {
                                    if (host === rootWindow) {
                                        stackLayout.currentIndex = idx;
                                    } else {
                                        host.layoutIndex = idx;
                                    }
                                });
                            }
                        }
                    }

                    Menu {
                        id: contextMenu
                        margins: 6 // keeps the menu inside the window, even for a small cell near an edge
                        
                        // When "Stream Select" is clicked, the menu auto-closes (Qt default
                        // for triggered items) which would instantly kill the submenu via
                        // onClosed. This flag lets the submenu survive that specific close.
                        property bool keepSubMenuOpen: false

                        // State of the per-camera detection indicator, read when the menu opens.
                        property bool targetOn: false
                        property bool targetAvailable: false
                        onAboutToShow: {
                            var p = playerPool.activePlayersMap[model.index];
                            targetAvailable = !!p && p.isHikvision && !p.isQuickPlayback;
                            targetOn = !!p && p.targetEnabledHere();
                        }
                        
                        topPadding: 5
                        bottomPadding: 5
                        
                        onClosed: {
                            if (!keepSubMenuOpen) {
                                streamSubMenu.close();
                                quickToolsSubMenu.close();
                                vcaSubMenu.close();
                            }
                            keepSubMenuOpen = false;
                        }
                        
                        // No open or close animation: the menu is shown at once. The rows stay put and turn gray
                        // when they do not apply, so opening does not have to rebuild the list.
                        
                        background: Rectangle {
                            implicitWidth: 160
                            color: "#151d24"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }
                        
                        MenuItem {
                            id: addCameraMenuItem
                            text: model.url === "" ? qsTr("LNG_00571") : qsTr("LNG_00572")
                            visible: true
                            enabled: true
                            leftPadding: 12

                            contentItem: Text {
                                text: addCameraMenuItem.text
                                font {
                                    pixelSize: 11
                                    bold: true
                                }
                                color: addCameraMenuItem.hovered ? "#00f5d4" : "#eeeeee"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }

                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: addCameraMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: addCameraMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }

                            onTriggered: {
                                addCameraDialog.targetIndex = model.index;
                                addCameraDialog.layoutModel = root.model;
                                addCameraDialog.open();
                            }
                        }

                        MenuItem {
                            text: qsTr("LNG_00475")
                            visible: true
                            enabled: model.url !== "" && generalSettings.allowSwappingViewports
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: parent.text
                                font {
                                    pixelSize: 11
                                    bold: true
                                }
                                color: parent.enabled ? (parent.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: parent.hovered ? "#2a3540" : "transparent"
                                border.color: parent.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }
                            
                            onTriggered: {
                                console.log("[CCTV Viewer Debug] Triggered context menu Zamień miejscami on index =", model.index);
                                root.pendingSwapSourceIndex = model.index;
                            }
                        }

                        MenuItem {
                            id: streamSelectMenuItem
                            text: qsTr("LNG_00474")
                            visible: true
                            enabled: model.url !== "" && generalSettings.enableStreamSelection
                            leftPadding: 12
                            
                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: streamSelectMenuItem.text
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: streamSelectMenuItem.enabled ? (streamSelectMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "▶"
                                    font {
                                        pixelSize: 9
                                        bold: true
                                    }
                                    color: streamSelectMenuItem.enabled ? (streamSelectMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: streamSelectMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: streamSelectMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onHoveredChanged: {
                                if (hovered && enabled) {
                                    root.popupBeside(streamSubMenu, streamSelectMenuItem);
                                }
                            }
                            
                            onTriggered: {
                                // Mark the submenu to survive the parent menu's
                                // auto-close, then open it.
                                contextMenu.keepSubMenuOpen = true;
                                root.popupBeside(streamSubMenu, streamSelectMenuItem);
                            }
                        }

                        MenuItem {
                            id: removeCameraMenuItem
                            text: qsTr("LNG_00473")
                            visible: true
                            enabled: model.url !== "" && generalSettings.enableRemoveCamera
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: removeCameraMenuItem.text
                                font {
                                    pixelSize: 11
                                    bold: true
                                }
                                color: removeCameraMenuItem.enabled ? (removeCameraMenuItem.hovered ? "#ff3333" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: removeCameraMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: removeCameraMenuItem.hovered ? "#ff3333" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }
                            
                            onTriggered: {
                                removeCameraConfirmDialog.index = model.index;
                                removeCameraConfirmDialog.open();
                            }
                        }


                        MenuItem {
                            id: snapshotMenuItem
                            text: qsTr("LNG_00470")
                            visible: true
                            enabled: model.url !== ""
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: snapshotMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: snapshotMenuItem.enabled ? (snapshotMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: snapshotMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: snapshotMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }
                            
                            onTriggered: {
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.takeSnapshot(false);
                                }
                            }
                        }


                        MenuItem {
                            id: playMenuItem
                            text: qsTr("LNG_00469")
                            visible: true
                            enabled: model.url !== ""
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: playMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: playMenuItem.enabled ? (playMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: playMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: playMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }
                            
                            onTriggered: {
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.openPlayback();
                                }
                            }
                        }

                        MenuItem {
                            id: webUiMenuItem
                            text: qsTr("Open camera web UI")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1
                            leftPadding: 12

                            contentItem: Text {
                                text: webUiMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: webUiMenuItem.enabled ? (webUiMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: webUiMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: webUiMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }

                            onTriggered: {
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.openCameraWebUi();
                                }
                            }
                        }


                        MenuItem {
                            id: quickToolsMenuItem
                            text: qsTr("Quick tools")
                            visible: true
                            enabled: model.url !== ""
                            leftPadding: 12

                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: quickToolsMenuItem.text
                                    font { pixelSize: 11; bold: true }
                                    color: quickToolsMenuItem.enabled ? (quickToolsMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "\u25B6"
                                    font { pixelSize: 9; bold: true }
                                    color: quickToolsMenuItem.enabled ? (quickToolsMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: quickToolsMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: quickToolsMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            onHoveredChanged: {
                                if (hovered && enabled) {
                                    streamSubMenu.close();
                                    vcaSubMenu.close();
                                    root.popupBeside(quickToolsSubMenu, quickToolsMenuItem);
                                }
                            }

                            onTriggered: {
                                contextMenu.keepSubMenuOpen = true;
                                root.popupBeside(quickToolsSubMenu, quickToolsMenuItem);
                            }
                        }

                        MenuItem {
                            id: vcaMenuItem
                            text: qsTr("VCA")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: vcaMenuItem.text
                                    font { pixelSize: 11; bold: true }
                                    color: vcaMenuItem.enabled ? (vcaMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "\u25B6"
                                    font { pixelSize: 9; bold: true }
                                    color: vcaMenuItem.enabled ? (vcaMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: vcaMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: vcaMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            onHoveredChanged: {
                                if (hovered && enabled) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    root.popupBeside(vcaSubMenu, vcaMenuItem);
                                }
                            }

                            onTriggered: {
                                contextMenu.keepSubMenuOpen = true;
                                root.popupBeside(vcaSubMenu, vcaMenuItem);
                            }
                        }

                        MenuItem {
                            id: targetMenuItem
                            text: (contextMenu.targetOn ? "\u2713 " : "    ") + qsTr("Detection frame")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable && generalSettings.showTargetIndicator
                            leftPadding: 12

                            contentItem: Text {
                                text: targetMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: targetMenuItem.enabled ? (targetMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: targetMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: targetMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: generalSettings.showTargetIndicator ? qsTr("Show a frame and label on this camera when it detects a human, vehicle or animal (only what is drawn; the detection log is set in General settings)") : qsTr("Turn on the detection frame in the settings window first")

                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }

                            onTriggered: {
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.toggleTargetHere();
                                }
                            }
                        }

                        MenuItem {
                            id: detectionLogMenuItem
                            text: qsTr("Detection events...")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: Text {
                                text: detectionLogMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: detectionLogMenuItem.enabled ? (detectionLogMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: detectionLogMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: detectionLogMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Show the latest detections logged for this camera")

                            onHoveredChanged: {
                                if (hovered) {
                                    streamSubMenu.close();
                                    quickToolsSubMenu.close();
                                    vcaSubMenu.close();
                                }
                            }

                            onTriggered: {
                                var player = playerPool.activePlayersMap[model.index];
                                if (!player)
                                    return;
                                var win = detectionLogComponent.createObject(rootWindow, {
                                    "cameraIp": player.detectionLogIp(),
                                    "cameraName": player.cameraNameInfo
                                });
                                if (win)
                                    win.show();
                            }
                        }

                    }

                    Menu {
                        id: quickToolsSubMenu
                        property string ruleIp: ""
                        onAboutToShow: {
                            var p = playerPool.activePlayersMap[model.index];
                            ruleIp = (p && p.isHikvision && !p.isQuickPlayback) ? p.detectionLogIp() : "";
                            root.refreshNoiseState(ruleIp);
                        }
                        margins: 6 // keeps the menu inside the window, even for a small cell near an edge

                        topPadding: 5
                        bottomPadding: 5

                        // No open or close animation: the menu is shown at once. The rows stay put and turn gray
                        // when they do not apply, so opening does not have to rebuild the list.

                        background: Rectangle {
                            implicitWidth: 200
                            color: "#151d24"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }

                        MenuItem {
                            id: reloadMenuItem
                            text: qsTr("LNG_00471")
                            visible: true
                            enabled: model.url !== "" && (playerPool.activePlayersMap[model.index] ? !playerPool.activePlayersMap[model.index].isQuickPlayback : true)
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: reloadMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: reloadMenuItem.enabled ? (reloadMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: reloadMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: reloadMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onTriggered: {
                            contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.reload();
                                }
                            }
                        }

                        MenuItem {
                            id: setupCheckMenuItem
                            text: qsTr("Check detection setup...")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: Text {
                                text: setupCheckMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: setupCheckMenuItem.enabled ? (setupCheckMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: setupCheckMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: setupCheckMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Read this camera's detection settings and list what is missing. It changes nothing.")

                            onTriggered: {
                            contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (!player)
                                    return;
                                var key = player.recorderIp + "#" + player.channelId;
                                rootWindow.checkDetectionSetup(key);
                                var win = setupCheckComponent.createObject(rootWindow, { "focusKey": key });
                                if (win)
                                    win.show();
                            }
                        }

                        MenuItem {
                            id: changeSettingsMenuItem
                            text: qsTr("LNG_00472")
                            visible: true
                            enabled: model.url !== "" && generalSettings.enableChangeViewportSettings
                            leftPadding: 12
                            
                            contentItem: Text {
                                text: changeSettingsMenuItem.text
                                font {
                                    pixelSize: 11
                                    bold: true
                                }
                                color: changeSettingsMenuItem.enabled ? (changeSettingsMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: changeSettingsMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: changeSettingsMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onTriggered: {
                            contextMenu.close();
                                viewportSettingsDialog.index = model.index;
                                viewportSettingsDialog.open();
                            }
                        }

                        MenuItem {
                            id: noiseFilterMenuItem
                            text: (root.noiseIsOn(quickToolsSubMenu.ruleIp) ? "\u2713 " : "    ") + qsTr("Noise filter (camera sound)")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                                     && root.noiseReady(quickToolsSubMenu.ruleIp) && !HikvisionBackup.ruleBusy
                            leftPadding: 12

                            contentItem: Text {
                                text: noiseFilterMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: noiseFilterMenuItem.enabled ? (noiseFilterMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: noiseFilterMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: noiseFilterMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Switch the camera's own \"Environmental Noise Filtering\" (web page: Video/Audio > Audio), which cleans the sound the camera sends. The camera is read first and then set the other way. Only this camera is changed.")

                            onTriggered: {
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player)
                                    root.toggleNoiseFilter(player.detectionLogIp(), player.cameraNameInfo);
                            }
                        }

                        MenuItem {
                            id: strobeStartMenuItem
                            text: qsTr("Activate Flashing Light")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                                     && root.strobeHas(quickToolsSubMenu.ruleIp) && !HikvisionBackup.ruleBusy
                            leftPadding: 12

                            contentItem: Text {
                                text: strobeStartMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: strobeStartMenuItem.enabled ? (strobeStartMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: strobeStartMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: strobeStartMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Make the camera's own flashing light flash now. It runs its programmed cycle and stops by itself (the time is set on the camera, 1 to 60 seconds). Some newer cameras (for example the G3 series) accept the command but have no on-demand strobe, so nothing flashes. Only this camera is changed.")

                            onTriggered: {
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player)
                                    root.runStrobe(player.detectionLogIp(), player.cameraNameInfo);
                            }
                        }

                        MenuItem {
                            id: warnMenuItem
                            text: qsTr("Play Warning Message")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                                     && root.warnHas(quickToolsSubMenu.ruleIp) && !HikvisionBackup.ruleBusy
                            leftPadding: 12

                            contentItem: Text {
                                text: warnMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: warnMenuItem.enabled ? (warnMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: warnMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: warnMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Make the camera play its own warning sound now. It is loud. The sound, volume and number of times are the ones set on the camera (web page: Event > Audio Alarm). Only this camera is changed.")

                            onTriggered: {
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player)
                                    root.runWarning(player.detectionLogIp(), player.cameraNameInfo);
                            }
                        }

                        MenuItem {
                            id: cameraSettingsMenuItem
                            text: qsTr("Camera settings")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: Text {
                                text: cameraSettingsMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: cameraSettingsMenuItem.enabled ? (cameraSettingsMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: cameraSettingsMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: cameraSettingsMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Open this camera's own settings (read only): device and status, time and network, video, picture, detection, alarms, storage. Nothing can be changed there.")

                            onTriggered: {
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player)
                                    root.openCameraSettings(player.detectionLogIp(), player.cameraNameInfo);
                            }
                        }

                        MenuItem {
                            id: rebootMenuItem
                            text: qsTr("Reboot Camera")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable && !HikvisionBackup.ruleBusy
                            leftPadding: 12

                            contentItem: Text {
                                text: rebootMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: rebootMenuItem.enabled ? (rebootMenuItem.hovered ? "#ff9f43" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: rebootMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: rebootMenuItem.hovered ? "#ff9f43" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Restart this camera. You are asked first. The camera is offline for a minute or two, so its video stops and nothing is recorded meanwhile. Only this camera is restarted, never the recorder.")

                            onTriggered: {
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player)
                                    root.askReboot(player.detectionLogIp(), player.cameraNameInfo);
                            }
                        }
                    }

                    Menu {
                        id: vcaSubMenu
                        // Read when the menu opens: the tile's player is kept in a plain map, which bindings do not follow.
                        // Both ticks are local. This menu does not ask the camera anything.
                        property bool targetsOn: false
                        property bool rulesOn: false
                        onAboutToShow: {
                            var p = playerPool.activePlayersMap[model.index];
                            targetsOn = !!p && p.vcaTargetsHere;
                            rulesOn = !!p && p.vcaRulesHere;
                        }
                        margins: 6 // keeps the menu inside the window, even for a small cell near an edge

                        topPadding: 5
                        bottomPadding: 5

                        // No open or close animation: the menu is shown at once. The rows stay put and turn gray
                        // when they do not apply, so opening does not have to rebuild the list.

                        background: Rectangle {
                            implicitWidth: 200
                            color: "#151d24"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }

                        MenuItem {
                            id: ruleLinesMenuItem
                            text: (vcaSubMenu.rulesOn ? "\u2713 " : "    ") + qsTr("Show VCA Line Rules")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: Text {
                                text: ruleLinesMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: ruleLinesMenuItem.enabled ? (ruleLinesMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: ruleLinesMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: ruleLinesMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Draw this camera's rule lines and zones on the picture, as iVMS-4200 does, in blue (red while that rule is in alarm). KVision reads them from the camera's smart data over its own light connection, so they show on the main stream and the sub-stream, including a panoramic camera that cannot draw them into the video. The camera is not changed. The tick is remembered for this camera.")

                            onTriggered: {
                                vcaSubMenu.close();
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.toggleVcaRulesHere();
                                    rootWindow.showNotice(qsTr("VCA line rules") + "\n" + (player.cameraNameInfo || player.recorderIp) + "\n"
                                                          + (player.vcaRulesHere ? qsTr("on") : qsTr("off")),
                                                          "#00f5d4", 2500);
                                }
                            }
                        }

                        MenuItem {
                            id: vcaTargetsMenuItem
                            text: (vcaSubMenu.targetsOn ? "\u2713 " : "    ") + qsTr("Target Boxes")
                            visible: true
                            enabled: model.url !== "" && String(model.url).indexOf("hikvision://") !== -1 && contextMenu.targetAvailable
                            leftPadding: 12

                            contentItem: Text {
                                text: vcaTargetsMenuItem.text
                                font { pixelSize: 11; bold: true }
                                color: vcaTargetsMenuItem.enabled ? (vcaTargetsMenuItem.hovered ? "#00f5d4" : "#eeeeee") : "#555555"
                                horizontalAlignment: Text.AlignLeft
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: vcaTargetsMenuItem.hovered ? "#2a3540" : "transparent"
                                border.color: vcaTargetsMenuItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("Draw a box on every person or vehicle the camera tracks, as iVMS-4200 does: green, red while it sets off a rule. KVision reads the camera's smart data over its own light connection (works on the main stream and the sub-stream); the camera is not changed.")

                            onTriggered: {
                                vcaSubMenu.close();
                                contextMenu.close();
                                var player = playerPool.activePlayersMap[model.index];
                                if (player) {
                                    player.toggleVcaTargetsHere();
                                    rootWindow.showNotice(qsTr("Target boxes") + "\n" + (player.cameraNameInfo || player.recorderIp) + "\n"
                                                          + (player.vcaTargetsHere ? qsTr("on") : qsTr("off")),
                                                          "#00f5d4", 2500);
                                }
                            }
                        }
                    }

                    Menu {
                        id: streamSubMenu
                        margins: 6 // keeps the menu inside the window, even for a small cell near an edge
                        
                        topPadding: 5
                        bottomPadding: 5
                        
                        // No open or close animation: the menu is shown at once. The rows stay put and turn gray
                        // when they do not apply, so opening does not have to rebuild the list.
                        
                        background: Rectangle {
                            implicitWidth: 160
                            color: "#151d24"
                            border.color: "#ff7a00"
                            border.width: 1
                            radius: 6
                        }
                        
                        MenuItem {
                            id: streamAutoItem
                            text: qsTr("LNG_00468")
                            leftPadding: 12
                            
                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: streamAutoItem.text
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: streamAutoItem.hovered ? "#00f5d4" : (viewport.streamMode === 0 ? "#00f5d4" : "#eeeeee")
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "✓"
                                    visible: viewport.streamMode === 0
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: "#00f5d4"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: streamAutoItem.hovered ? "#2a3540" : "transparent"
                                border.color: streamAutoItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onTriggered: root.pickTileStream(model.index, 0)
                        }
                        
                        MenuItem {
                            id: streamMainItem
                            text: qsTr("LNG_00467")
                            leftPadding: 12
                            
                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: streamMainItem.text
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: streamMainItem.hovered ? "#00f5d4" : (viewport.streamMode === 1 ? "#00f5d4" : "#eeeeee")
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "✓"
                                    visible: viewport.streamMode === 1
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: "#00f5d4"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: streamMainItem.hovered ? "#2a3540" : "transparent"
                                border.color: streamMainItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onTriggered: root.pickTileStream(model.index, 1)
                        }
                        
                        MenuItem {
                            id: streamSubItem
                            text: qsTr("LNG_00466")
                            leftPadding: 12
                            
                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: streamSubItem.text
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: streamSubItem.hovered ? "#00f5d4" : (viewport.streamMode === 2 ? "#00f5d4" : "#eeeeee")
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "✓"
                                    visible: viewport.streamMode === 2
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: "#00f5d4"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }
                            
                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: streamSubItem.hovered ? "#2a3540" : "transparent"
                                border.color: streamSubItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }
                            
                            onTriggered: root.pickTileStream(model.index, 2)
                        }

                        MenuItem {
                            id: streamThirdItem
                            text: qsTr("Third")
                            visible: true
                            enabled: String(viewport.url).indexOf("hikvision://") === 0
                            leftPadding: 12

                            contentItem: RowLayout {
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: streamThirdItem.text
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: streamThirdItem.enabled ? (streamThirdItem.hovered ? "#00f5d4" : (viewport.streamMode === 3 ? "#00f5d4" : "#eeeeee")) : "#555555"
                                    horizontalAlignment: Text.AlignLeft
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    text: "✓"
                                    visible: viewport.streamMode === 3
                                    font {
                                        pixelSize: 11
                                        bold: true
                                    }
                                    color: "#00f5d4"
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    rightPadding: 8
                                }
                            }

                            background: Rectangle {
                                implicitWidth: 150
                                implicitHeight: 32
                                color: streamThirdItem.hovered ? "#2a3540" : "transparent"
                                border.color: streamThirdItem.hovered ? "#00f5d4" : "transparent"
                                border.width: 1
                                radius: 4
                            }

                            onTriggered: root.pickTileStream(model.index, 3)
                        }
                    }

                    // DropArea ON TOP of everything — accepts both camera and viewport drops
                    DropArea {
                        id: dropArea
                        anchors.fill: parent

                        // Highlight on drag hover
                        Rectangle {
                            anchors.fill: parent
                            color: dropArea.containsDrag ? "#3000f5d4" : "transparent"
                            border.color: dropArea.containsDrag ? "#00f5d4" : "transparent"
                            border.width: 2
                            z: 100

                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        onEntered: {
                            if (drag.hasFormat("application/x-cctv-viewport-index") || drag.hasFormat("application/x-cctv-camera-url") || drag.hasText) {
                                drag.accept();
                            } else {
                                drag.accepted = false;
                            }
                        }

                        onPositionChanged: {
                            if (drag.hasFormat("application/x-cctv-viewport-index") || drag.hasFormat("application/x-cctv-camera-url") || drag.hasText) {
                                drag.accept();
                            } else {
                                drag.accepted = false;
                            }
                        }

                        onDropped: {
                            // Camera drop from NvrCamerasWindow
                            if (drop.hasText) {
                                var url = "";
                                // Try custom MIME type first
                                if (drop.hasFormat("application/x-cctv-camera-url")) {
                                    url = drop.getDataAsString("application/x-cctv-camera-url");
                                } else {
                                    url = drop.text;
                                }

                                if (url && url.indexOf("hikvision://") === 0) {
                                    root.model.get(model.index).url = url;
                                    root.model.get(model.index).secondaryUrl = url;
                                    root.model.get(model.index).streamMode = rootWindow.streamModeForUrl(url);
                                    rootWindow.noteCameraPlaced(root.model, url);
                                    drop.accept(Qt.CopyAction);
                                    Utils.log_info("Dropped camera on viewport " + (model.index + 1));
                                    return;
                                }
                            }

                            // Viewport swap
                            if (drop.hasFormat("application/x-cctv-viewport-index")) {
                                var sourceIndex = parseInt(drop.getDataAsString("application/x-cctv-viewport-index"));
                                if (d.swapViewportItems(sourceIndex, model.index))
                                    drop.accept(Qt.MoveAction);
                                return;
                            }
                        }
                    }

                    function indexAt(x, y) {
                        for (var i = 0; i < repeater.count; ++i) {
                            var itemTo = repeater.itemAt(i);
                            if (!itemTo || !itemTo.active)
                                continue;

                            if (i === model.index) {
                                if (contains(Qt.point(x, y))) {
                                    return i;
                                }
                            } else {
                                var mappedPoint = mapToItem(itemTo, x, y);

                                if (itemTo.contains(mappedPoint)) {
                                    return i;
                                }
                            }
                        }

                        return -1;
                    }
                }
            }
                }
            }
        }
    }

    // Right-click > stream: save it on this tile. Auto is the default, so it clears Exclude.
    // Main, Sub, and Third are exceptions, so this layout is left out of the camera-wide choice.
    function pickTileStream(index, mode) {
        var item = root.model.get(index);
        if (!item)
            return;
        item.streamMode = mode;
        var key = rootWindow.tileKeyFromUrl(item.url);
        if (key === "")
            return;
        // One tile set back to Auto must not clear the flag while another tile of this camera is still Main, Sub, or Third.
        if (mode === 0) {
            if (!rootWindow.layoutHasNonAuto(root.model, key))
                rootWindow.releaseCameraOnLayout(root.model, key);
        } else
            rootWindow.excludeCameraOnLayout(root.model, key);
    }

    Keys.onPressed: {
        d.keyModifiers = event.modifiers;

        switch (event.key) {
        case Qt.Key_Delete:
            for (var i = 0; i < root.size.width * root.size.height; ++i) {
                var selectedCell = root.get(i);
                if (selectedCell && selectedCell.selected) {
                    model.get(i).url = "";
                    model.get(i).secondaryUrl = "";
                    model.get(i).volume = 0;
                    model.get(i).avFormatOptions = layoutsCollectionSettings.toJSValue("defaultAVFormatOptions");
                    model.get(i).streamMode = 0;
                }
            }
            break;
        }
    }
    Keys.onReleased: d.keyModifiers = event.modifiers

    function get(index) {
        if (index >= 0 && index < repeater.count) {
            var shell = repeater.itemAt(index);
            // Covered cells stay unloaded, so there is no viewport to focus.
            // A maximized picture is parented to the layout, not to its cell, so follow the reference.
            if (shell === null || !shell.item)
                return undefined;
            if (shell.item.viewportItem)
                return shell.item.viewportItem;
            if (!shell.item.children || shell.item.children.length < 1)
                return undefined;

            return shell.item.children[0];
        }

        return undefined;
    }

    function indexAt(x, y) {
        // The maximized camera is drawn over the grid. Points on that picture belong to it,
        // not to the cells sitting underneath.
        if (d.fullScreenIndex >= 0 && x >= 0 && y >= 0 && x < width && y < height)
            return d.fullScreenIndex;
        for (var i = 0; i < repeater.count; ++i) {
            var itemTo = repeater.itemAt(i);
            if (!itemTo || !itemTo.active)
                continue;
            var mappedPoint = mapToItem(itemTo, x, y);

            if (itemTo.contains(mappedPoint)) {
                return i;
            }
        }

        return -1;
    }

    // M mutes the focused tile. The next press puts back the level it had, rather than full volume.
    function toggleTileMute(index) {
        var item = root.model ? root.model.get(index) : null;
        var cell = root.get(index);
        if (!item || !cell || !cell.hasAudio)
            return;
        if (item.volume > 0) {
            cell.audibleVolume = item.volume;
            item.volume = 0;
        } else {
            var back = cell.audibleVolume;
            item.volume = back > 0 ? back : 1;
        }
    }

    // Ctrl+wheel digital zoom. x and y are in this layout's coordinates, which include the
    // letterbox around the grid. A camera that fills the layout is the target. Otherwise it is
    // the cell under the pointer, and that cell is opened first.
    function digitalZoomAt(x, y, angleDeltaY) {
        if (!angleDeltaY)
            return false;
        var idx = d.fullScreenIndex;
        if (idx < 0)
            idx = indexAt(x, y);
        var cell = (idx >= 0) ? root.get(idx) : null;
        if (!cell)
            return false;
        if (!cell.fullScreen && (root.size.width > 1 || root.size.height > 1)) {
            cell.fullScreen = true;
            cell.forceActiveFocus();
            d.selectionReset();
        }
        var local = cell.mapFromItem(root, x, y);
        cell.zoomByWheelAt(local.x, local.y, angleDeltaY);
        return true;
    }

    // If the tile under (x, y) (in this layout's coordinates) is box-zoomed, zoom it with the wheel.
    // Returns true when the wheel event was consumed.
    // A maximized camera ignores this: its wheel moves to the next camera in the layout.
    function boxZoomWheelAt(x, y, angleDeltaY, modifiers) {
        if (d.fullScreenIndex >= 0)
            return false;
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
            return false;
        }
        var idx = indexAt(x, y);
        if (idx < 0) {
            return false;
        }
        var p = playerPool.activePlayersMap[idx];
        if (!p || !p.isZoomed) {
            return false;
        }
        var pp = p.mapFromItem(root, x, y);
        p.zoomByWheel(angleDeltaY, pp.x, pp.y);
        return true;
    }

    function mergeCells(testMode) {
        if (!d.selectionActive)
            return false;
        var left = d.selectionLeft();
        var top = d.selectionTop();
        var w = d.selectionWidth();
        var h = d.selectionHeight();
        if (w <= 0 || h <= 0 || (w >= root.size.width && h >= root.size.height))
            return false;
        var topLeftIndex = d.indexFromAddress(left, top);
        if (topLeftIndex < 0 || topLeftIndex >= model.count)
            return false;
        var topLeftElement = model.get(topLeftIndex);
        if (!topLeftElement || topLeftElement.visible !== ViewportsLayoutItem.Visible)
            return false;

        // The block is one tile already: a plain cell does nothing, a joined tile splits.
        var oneTile = topLeftElement.columnSpan === w && topLeftElement.rowSpan === h;
        if (oneTile && w === 1 && h === 1)
            return false;
        if (testMode)
            return true;

        if (oneTile) {
            topLeftElement.columnSpan = 1;
            topLeftElement.rowSpan = 1;
        } else {
            // Drop joins inside the block first. A leftover join makes normalize reject the new one.
            for (var r = top; r < top + h; ++r) {
                for (var c = left; c < left + w; ++c) {
                    var idx = d.indexFromAddress(c, r);
                    var it = model.get(idx);
                    if (!it || it.visible !== ViewportsLayoutItem.Visible)
                        continue;
                    it.columnSpan = 1;
                    it.rowSpan = 1;
                }
            }
            topLeftElement = model.get(topLeftIndex);
            if (topLeftElement) {
                topLeftElement.columnSpan = w;
                topLeftElement.rowSpan = h;
            }
        }
        model.normalize();
        d.refreshSelection();
        return true;
    }

    AddCameraDialog {
        id: addCameraDialog
    }

    // The setup check window lists what the check found for each camera.
    Component {
        id: cameraSettingsComponent
        CameraSettingsWindow {}
    }

    Component {
        id: setupCheckComponent
        SetupCheckWindow {}
    }

    // The detection log window is created each time it is opened, so there can be one per camera.
    Component {
        id: detectionLogComponent
        DetectionLogWindow {}
    }

    // Keyboard navigation (or any other focus change) also moves the Add camera target
    Connections {
        target: d
        function onFocusIndexChanged() {
            if (addCameraDialog.visible && addCameraDialog.layoutModel === root.model && d.focusIndex >= 0) {
                addCameraDialog.targetIndex = d.focusIndex;
            }
        }
    }

    ConfirmDialog {
        id: rebootConfirm
        title: qsTr("Reboot camera")
        iconSource: "qrc:/images/icon-warning.svg"
        confirmButtonText: qsTr("Reboot")
        property string camIp: ""
        property string camName: ""
        message: qsTr("Restart %1 (%2)?").arg(camName).arg(camIp) + "\n\n"
                 + qsTr("The camera goes offline for a minute or two: its video stops and nothing is recorded from it meanwhile. Only this camera is restarted.")
        onAccepted: root.runReboot(camIp, camName)
    }

    ConfirmDialog {
        id: removeCameraConfirmDialog
        title: qsTr("LNG_00465")
        iconSource: "qrc:/images/icon-trash.svg"
        message: qsTr("LNG_00464")
        property int index: -1
        
        onAccepted: {
            if (index >= 0 && index < root.model.count) {
                var item = root.model.get(index);
                if (item) {
                    item.url = "";
                    item.secondaryUrl = "";
                    item.volume = 0.0;
                    item.avFormatOptions = {};
                    item.streamMode = 0;
                }
            }
        }
    }

    ViewportSettingsDialog {
        id: viewportSettingsDialog
    }
}
