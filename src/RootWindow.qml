import QtQml 2.11
import QtQuick 2.11
import QtQuick.Window 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import QtQuick.Dialogs 1.3
import Qt.labs.settings 1.0
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Models 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Themes 1.0
import CCTV_Viewer.Hikvision 1.0
import Qt.labs.platform 1.1 as Platform

ApplicationWindow {
    id: rootWindow

    title: (Context.isAuxiliary ? qsTr("LNG_00018") : qsTr("LNG_00003")) + " " + Qt.application.version

    visible: true
    visibility: Context.config.fullScreen ? Window.FullScreen : Window.Windowed

    property bool isWindowMinimized: rootWindow.visibility === Window.Minimized
    property int lastNonMinimizedVisibility: Window.Windowed
    property bool closeAccepted: false
    property string lastLoadedModelsJson: ""
    property string lastSavedModelsJson: ""
    property bool isSyncing: false
    property bool topBarAutoCollapse: !viewSettings.showTopBarByDefault
    // The auxiliary window is not scaled with the 4K screen, so its toolbar is drawn larger to stay easy to use.
    readonly property real toolbarScale: Context.isAuxiliary ? 1.5 : 1
    function toolbarPx(n) { return Math.round(n * rootWindow.toolbarScale) }
    readonly property bool isPlaybackWindowOpen: playbackWindowLoader.active && playbackWindowLoader.item && playbackWindowLoader.item.visible
    // True when the auto-hide timer has blanked the mouse cursor (fullscreen inactivity).
    // Viewport overlays (hover buttons, etc.) use this to fade out together with the cursor.
    readonly property bool cursorHidden: cursorShape.hidden
    // True after a few idle seconds when "hide info badges when idle" is enabled
    readonly property bool infoBadgesIdleHidden: viewSettings.hideInfoBadgesWhenIdle && infoIdleState.idle

    onClosing: {
        if (!closeAccepted && generalSettings.confirmOnClose) {
            close.accepted = false;
            quitConfirmDialog.open();
        }
    }

    Timer {
        id: restoreVisibilityTimer
        interval: 150
        repeat: false
        property int targetVisibility: Window.Windowed
        onTriggered: {
            if (targetVisibility === Window.FullScreen) {
                rootWindow.showFullScreen();
            } else if (targetVisibility === Window.Maximized) {
                rootWindow.showMaximized();
            } else {
                rootWindow.showNormal();
            }
        }
    }

    Timer {
        id: saveTimer
        interval: 350
        repeat: false
        onTriggered: {
            if (rootWindow.isSyncing) return;
            var json = rootWindow.persistedLayoutsJson();
            rootWindow.lastSavedModelsJson = json;
            layoutsCollectionSettings.models = json;
            console.log("[Sync] Debounced layouts save completed.");
        }
    }

    // Automatic layout backups (see LayoutBackups): at most one per layout in 20 hours, and only when the layout has changed.
    Timer {
        id: layoutBackupTimer
        interval: 6 * 3600 * 1000
        repeat: true
        triggeredOnStart: false
        running: !Context.isAuxiliary
        onTriggered: rootWindow.backUpLayouts()
    }
    Timer {
        id: layoutBackupFirstTimer
        interval: 60 * 1000
        repeat: false
        running: !Context.isAuxiliary
        onTriggered: rootWindow.backUpLayouts()
    }

    function backUpLayouts() {
        if (Context.isAuxiliary || rootWindow.isSyncing || layoutsCollectionModel.count === 0)
            return;
        var n = LayoutBackups.autoBackup(rootWindow.persistedLayoutsJson(), 20);
        if (n > 0)
            console.log("[Layouts] automatic backup of", n, "layout(s)");
    }

    Timer {
        id: syncEndTimer
        interval: 500
        repeat: false
        onTriggered: {
            rootWindow.isSyncing = false;
            console.log("[Sync] isSyncing set to false after safety delay.");
        }
    }

    onVisibilityChanged: {
        if (visibility === Window.Minimized) {
            isWindowMinimized = true;
            return;
        }

        if (isWindowMinimized) {
            return;
        }

        if (visibility === Window.FullScreen) {
            Context.config.fullScreen = true;
        } else if (visibility === Window.Windowed || visibility === Window.Maximized) {
            lastNonMinimizedVisibility = visibility;
            if (active) {
                Context.config.fullScreen = false;
            }
        }
    }

    Connections {
        target: Context.config
        function onFullScreenChanged() {
            if (Context.config.fullScreen) {
                rootWindow.visibility = Window.FullScreen;
            } else {
                rootWindow.visibility = (rootWindow.lastNonMinimizedVisibility === Window.Maximized) ? Window.Maximized : Window.Windowed;
            }
        }
    }

    width: Math.max(rootWindowSettings.width, 960)
    height: Math.max(rootWindowSettings.height, 600)
    minimumWidth: 960
    minimumHeight: 600

    // Right-to-left User Interfaces support
    LayoutMirroring.enabled: Qt.application.layoutDirection == Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    Binding {
        target: rootWindowSettings
        property: "width"
        value: rootWindow.width
        when: !Context.config.fullScreen
    }

    Binding {
        target: rootWindowSettings
        property: "height"
        value: rootWindow.height
        when: !Context.config.fullScreen
    }

    property bool recordersSealing: false
    property bool recordersSecretsReady: false
    // This copy keeps passwords for the running app. The settings file keeps the sealed copy.
    property string hikvisionRecordersJson: RecorderSecrets.open(hikvisionSettings.recordersJson, Context.config.fileName)
    onHikvisionRecordersJsonChanged: {
        rootWindow.applyEventLogger()
        if (!rootWindow.recordersSecretsReady || rootWindow.recordersSealing)
            return
        var sealed = RecorderSecrets.seal(rootWindow.hikvisionRecordersJson, Context.config.fileName)
        if (sealed !== "" && sealed !== hikvisionSettings.recordersJson) {
            rootWindow.recordersSealing = true
            hikvisionSettings.recordersJson = sealed
            rootWindow.recordersSealing = false
        }
    }
    // A recorder was set offline or back online: stop or start its camera connections.
    Connections {
        target: NvrStatusManager
        function onOfflineChanged() { rootWindow.applyEventLogger() }
    }
    property alias layoutRepeater: layoutRepeater
    property alias layoutIndex: stackLayout.currentIndex
    property alias generalSettings: generalSettings
    property alias viewSettings: viewSettings
    property var auxWindowsList: []
    property var activeLayoutWindow: rootWindow
    
    // Permanent caches for NVR searches to avoid constantly reloading from network
    property var monthAvailabilitiesCache: ({})
    property var playbackSegmentsCache: ({})
    property var playbackEventsCache: ({})

    // The colour of an event tick on a playback timeline, by what the recorder says the event was. The order is the
    // drawing order, so the rarer smart events end up on top of motion.
    // Adds what the detection log holds for a camera to the events a recorder saved (searchStartMs is the start of the
    // search, three days wide). A logged event is left out when the recorder has the same kind within 3 seconds.
    // Logged events carry log: true, and the timelines draw them as a thinner strip.
    function mergeLogEvents(recorderIp, channelId, searchStartMs, segments) {
        var logged = HikvisionEvents.logEventsBetween(recorderIp, channelId, searchStartMs, searchStartMs + 3 * 86400000, Context.configDirPath());
        for (var i = 0; i < logged.length; ++i) {
            var l = logged[i];
            var have = false;
            for (var j = 0; j < segments.length; ++j) {
                if (segments[j].kind === l.kind && Math.abs(segments[j].startTime - l.startTime) <= 3000) {
                    have = true;
                    break;
                }
            }
            if (!have)
                segments.push({ "startTime": l.startTime, "endTime": l.endTime, "event": true, "kind": l.kind, "log": true });
        }
        return segments;
    }

    // True when a time span overlaps any of the recorded segments (each {startTime, endTime} in ms). Used so an event
    // that only the detection log has is drawn only where the bar shows video. With no segments loaded yet it is false.
    function overlapsRecording(segments, startMs, endMs) {
        if (!segments)
            return false;
        for (var i = 0; i < segments.length; ++i) {
            if (segments[i] && segments[i].startTime < endMs && segments[i].endTime > startMs)
                return true;
        }
        return false;
    }

    readonly property var eventKindOrder: ["motion", "other", "enter", "exit", "line", "intrusion"]
    function eventKindColor(kind) {
        return kind === "line" ? "#ff3344"
             : (kind === "intrusion" ? "#ff00c8"
             : (kind === "enter" ? "#3a86ff"
             : (kind === "exit" ? "#8338ec"
             : (kind === "other" ? "#cfd8dc" : "#ffd23f"))));
    }
    function eventKindName(kind) {
        return kind === "line" ? qsTr("Line crossing")
             : (kind === "intrusion" ? qsTr("Intrusion")
             : (kind === "enter" ? qsTr("Region entrance")
             : (kind === "exit" ? qsTr("Region exit")
             : (kind === "other" ? qsTr("Other smart event") : qsTr("Motion")))));
    }

    onActiveChanged: {
        if (active) {
            rootWindow.activeLayoutWindow = rootWindow;
            
            if (isWindowMinimized) {
                isWindowMinimized = false;
                if (Context.config.fullScreen) {
                    restoreVisibilityTimer.targetVisibility = Window.FullScreen;
                    restoreVisibilityTimer.start();
                }
            }
        }
    }

    Settings {
        id: generalSettings

        fileName: Context.config.fileName
        property bool singleApplication: true
        property bool allowSwappingViewports: true
        property bool enableContextMenu: true
        property bool enableRemoveCamera: true
        property bool enableChangeViewportSettings: true
        property bool enableStreamSelection: true
        property bool lockGridSize: false
        property string snapshotPath: ""
        property string videoPath: ""
        property bool disableAudio: false
        property bool disableTalk: false
        // The browser KVision opens web pages in: "" = the system default, "id:<launcher>.desktop", or "cmd:<command>".
        property string webBrowserChoice: ""
        onWebBrowserChoiceChanged: WebBrowser.setChoice(webBrowserChoice)
        property bool showTargetIndicator: false
        property int targetHoldSeconds: 10
        property int picturesPerCamera: 100
        // Where cameras behind a recorder get their detection reports: "camera" (each camera directly) or
        // "recorder" (one connection to the recorder). Standalone cameras always use their own connection.
        property string targetSource: "camera"
        // Where one camera behind a recorder gets its reports from, when it is not the general choice above:
        // JSON {"<recorderIp>#<channel>": "camera" | "recorder"}.
        property string targetSourceOverrides: "{}"
        onTargetSourceOverridesChanged: rootWindow.applyEventLogger()
        // Which kinds of report may show a frame (comma list: motion,line,intrusion,enter,exit,other) and which
        // targets (human,vehicle,animal,other).
        property string targetKinds: "motion,line,intrusion,enter,exit,face,other"
        property string overlayText: "{}" // JSON: the settings of the MQTT overlay text (Overlay text from MQTT window)
        property bool overlayTextUserCleared: false // true after the overlay window saves an empty list on purpose
        // Keep logging after the window is closed (the background service). While the window is open every camera is
        // always logged, whether or not a tile shows it; the on-screen frame (showTargetIndicator and the right-click
        // switch) only decides what is drawn.
        property bool logDetectionEvents: false
        property bool checkSetupAtStart: false // read each camera's detection setup once when KVision starts
        property string targetTargets: "human,vehicle,animal,other"
        // Motion reports that name no target (the camera's motion detection is not a smart event): write each movement to the
        // detection log, and show a "MOTION" frame for it. Both off until switched on.
        property bool logUnlabelledMotion: false
        property bool frameUnlabelledMotion: false
        onLogUnlabelledMotionChanged: rootWindow.applyDetectionFilters()
        onFrameUnlabelledMotionChanged: rootWindow.applyDetectionFilters()
        property string targetOffCameras: "[]" // JSON list of camera addresses with the indicator switched off
        property string targetNvrOnCameras: "[]" // JSON list of "recorderIp#channel" entries switched on for cameras behind a recorder
        // Right-click > VCA > Target Boxes on a live Hikvision tile: KVision draws the camera's tracked targets
        // (read from its smart data, as iVMS-4200 does). JSON list of "recorderIp#channel".
        property string vcaTargetsOnCameras: "[]"
        // Right-click > VCA > Show VCA Line Rules: KVision draws the rule lines from the same smart data.
        // JSON list of "recorderIp#channel". The camera's own stream switch is left alone.
        property string vcaRuleLinesOnCameras: "[]"
        // Settings > Audio > Choose cameras: live Hikvision tiles whose AAC description is repaired
        // on this computer. JSON list of "recorderIp#channel". Empty leaves every stream direct.
        property string repairAacCameras: "[]"
        // Camera Tools > Video stream: the picture a camera's tiles use, remembered per camera.
        // JSON {"ip#channel": 1 | 2 | 3} for Main, Sub and Third. A camera with no entry stays on
        // whatever each layout already has (Auto, until a layout says otherwise).
        property string tileStreamByCamera: "{}"
        onTargetNvrOnCamerasChanged: rootWindow.noteNvrList()
        Component.onCompleted: rootWindow.nvrListReady = true
        property string talkMicrophone: ""
        property real talkGain: 2.0
        property real talkBoostDb: 0.0
        property int auxiliaryLimit: 1
        // Scale of an auxiliary window: "same" keeps the main window's scale, otherwise "1", "1.5" or "2".
        // Applied the next time an auxiliary window opens. "1" fits a 1080p screen when the main window is scaled for 4K.
        property string auxiliaryScale: "1"
        property int playbackOffsetSeconds: 120
        property int playbackTimelineHours: 2
        // Drop this window's live pictures while the archive is open, and connect them again when it closes.
        property bool pauseLiveDuringPlayback: true
        // Draw the camera's rule lines/zones and target boxes stored in the recording (Hikvision playback)
        property bool showPlaybackVcaOverlay: true
        property bool enableDiagnosticLogs: false
        property bool confirmOnClose: true
        // The statistics panel's history window, in minutes. Saved here, read
        // by every KVision process when it starts, changed from the panel.
        property int statsHistoryMinutes: 15
        onStatsHistoryMinutesChanged: SystemStats.historyMinutes = statsHistoryMinutes
        // System Stats temperature graph. "C" or "F". Samples stay in Celsius;
        // only the panel's numbers and scale change.
        property string statsTemperatureUnit: "C"
    }

    Settings {
        id: hikvisionSettings
        fileName: Context.config.fileName
        category: "Hikvision"
        property string recordersJson: "[]"
        onRecordersJsonChanged: NvrStatusManager.onRecordersChanged()
        Component.onCompleted: {
            var path = Context.config.fileName
            var disk = Context.readSetting("Hikvision", "recordersJson", "")
            if (disk === "") {
                rootWindow.recordersSecretsReady = true
                return
            }
            var opened = RecorderSecrets.open(disk, path)
            var sealed = RecorderSecrets.seal(opened, path)
            rootWindow.recordersSealing = true
            if (rootWindow.hikvisionRecordersJson !== opened)
                rootWindow.hikvisionRecordersJson = opened
            if (sealed !== "" && recordersJson !== sealed)
                recordersJson = sealed
            rootWindow.recordersSealing = false
            rootWindow.recordersSecretsReady = true
        }
    }


    function getRecorderName(ip) {
        try {
            var list = JSON.parse(hikvisionSettings.recordersJson);
            for (var i = 0; i < list.length; ++i) {
                if (list[i].kind === "rtsp")
                    continue;
                if (list[i].ip === ip) {
                    if (list[i].name && list[i].name.trim() !== "") {
                        return list[i].name;
                    }
                    break;
                }
            }
        } catch(e) {
            console.log("[RootWindow Error] Failed to parse recorders JSON:", e);
        }
        return ip;
    }

    function layoutDisplayName(collection, index) {
        try {
            var layout = collection.get(index);
            if (!layout) {
                return "Widok " + (index + 1);
            }
            if (layout.name && layout.name.trim() !== "") {
                return layout.name;
            }
            if (layout.isNvr) {
                return "📹 " + getRecorderName(layout.nvrIp);
            }
            var count = 1;
            for (var i = 0; i < index; ++i) {
                var other = collection.get(i);
                if (other && !other.isNvr) count++;
            }
            return "Widok " + count;
        } catch (e) {
            return "Widok " + (index + 1);
        }
    }

    function layoutIsPageable(collection, index) {
        try {
            var layout = collection.get(index);
            if (!layout) return false;
            if (layout === scratchLayout) return false;
            return layout.visible !== false;
        } catch (e) {
            return true;
        }
    }

    property var toolbarLayoutModel: []
    // Set while a preset row is moved, so the layout on screen is not stopped and started again.
    property bool layoutReorderHold: false
    // Bumped whenever the layout order changes, so the list and the toolbar buttons re-read that order.
    property int layoutOrderRevision: 0

    // Reorder the saved layouts without letting the screen switch to a different one along the way.
    // The stack follows the moved row after this function returns, so the index is put back
    // on the next turn while the hold is still set.
    function moveLayoutKeepingView(fromIndex, toIndex) {
        var showing = layoutsCollectionModel.get(stackLayout.currentIndex);
        layoutReorderHold = true;
        layoutsCollectionModel.move(fromIndex, toIndex);
        Qt.callLater(function() {
            if (showing) {
                for (var j = 0; j < layoutsCollectionModel.count; ++j) {
                    if (layoutsCollectionModel.get(j) === showing) {
                        if (stackLayout.currentIndex !== j)
                            stackLayout.currentIndex = j;
                        break;
                    }
                }
            }
            layoutReorderHold = false;
            windowLayoutSettings.currentIndex = stackLayout.currentIndex;
        });
    }

    function refreshToolbarLayouts() {
        layoutOrderRevision = layoutOrderRevision + 1;
        toolbarLayoutModel = toolbarLayoutIndices(layoutsCollectionModel)
    }

    function toolbarLayoutIndices(collection) {
        var indices = [];
        if (!collection) return indices;
        for (var i = 0; i < collection.count; ++i) {
            if (layoutIsPageable(collection, i)) indices.push(i);
        }
        return indices;
    }

    // Step through the same visible saved layouts shown on the top bar.
    // direction > 0 moves to the next page (scroll down), < 0 to the previous.
    function stepVisibleLayout(collection, currentIndex, direction) {
        if (!collection || collection.count < 1) return -1;
        var count = collection.count;
        var start = currentIndex;
        if (start < 0 || start >= count) {
            start = direction > 0 ? -1 : 0;
        }
        for (var step = 1; step <= count; ++step) {
            var idx = (start + direction * step) % count;
            if (idx < 0) idx += count;
            if (layoutIsPageable(collection, idx)) return idx;
        }
        return -1;
    }

    function showLayoutToast(name) {
        layoutToastText.text = name;
        layoutToast.opacity = 1.0;
        layoutToastHideTimer.restart();
    }

    // Vertical wheel first. A sideways tilt still counts, so one notch is never dropped.
    function wheelDeltaY(wheel) {
        if (!wheel)
            return 0;
        if (wheel.angleDelta.y !== 0)
            return wheel.angleDelta.y;
        if (wheel.pixelDelta && wheel.pixelDelta.y !== 0)
            return wheel.pixelDelta.y;
        if (wheel.angleDelta.x !== 0)
            return wheel.angleDelta.x;
        return 0;
    }

    // One notch of the wheel. Shared by layout changes and by stepping cameras while one is maximized.
    function wheelStepAllowed() {
        if (layoutWheelDebounce.running)
            return false;
        layoutWheelDebounce.start();
        return true;
    }

    function handleLayoutWheel(wheel, collection, currentIndex, applyIndex) {
        if (!wheel || !collection) return;
        if (wheel.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        if (wheel.buttons !== Qt.NoButton) return;

        var focus = rootWindow.activeFocusItem;
        if (focus && (focus instanceof TextInput || focus instanceof TextEdit)) return;
        if (quitConfirmDialog.visible || nvrStatusDialog.visible || aacRepairDialog.visible) return;
        if (sidebarWindow.visible || toolsWindow.visible || instructionsWindow.visible) return;
        if (rootWindow.isPlaybackWindowOpen) return;
        if (layoutWheelDebounce.running) {
            wheel.accepted = true;
            return;
        }

        var delta = wheel.angleDelta.y;
        if (delta === 0 && wheel.pixelDelta) delta = wheel.pixelDelta.y;
        if (delta === 0) return;
        if (!wheelStepAllowed()) {
            wheel.accepted = true;
            return;
        }

        var next = stepVisibleLayout(collection, currentIndex, delta > 0 ? 1 : -1);
        if (next < 0 || next === currentIndex) return;

        applyIndex(next);
        showLayoutToast(layoutDisplayName(collection, next));
        wheel.accepted = true;
    }

    Timer {
        id: layoutWheelDebounce
        interval: 220
        repeat: false
    }

    Timer {
        id: layoutToastHideTimer
        interval: 900
        repeat: false
        onTriggered: layoutToast.opacity = 0.0
    }


    Timer {
        id: keepVisibleTimer
        interval: 350
        repeat: false
    }

    Settings {
        id: rootWindowSettings

        fileName: Context.config.fileName
        category: Context.isAuxiliary ? "AuxiliaryWindow_" + Context.auxiliaryId : "RootWindow"
        property int width: 1280 + 48 // SideBar compact width
        property int height: 720
        property bool fullScreen

        Component.onCompleted: {
            // Do not initialize "fullScreen" if option "-f" is set
            if (!Context.config.fullScreen) {
                Context.config.fullScreen = rootWindowSettings.fullScreen;
            }

            rootWindowSettings.fullScreen = Qt.binding(function() { return Context.config.fullScreen; });
        }
    }

    Settings {
        id: windowLayoutSettings
        fileName: Context.config.fileName
        category: Context.isAuxiliary ? "AuxiliaryLayout_" + Context.auxiliaryId : "MainLayout"
        property int currentIndex: 0
    }

    Connections {
        target: Context
        function onConfigFileChanged() {
            // 1. Check and live-reload Hikvision NVR/Cameras recorders list
            var diskRecorders = Context.readSetting("Hikvision", "recordersJson", "");
            if (diskRecorders === "")
                diskRecorders = "[]";
            var openedRecorders = RecorderSecrets.open(diskRecorders, Context.config.fileName);
            if (openedRecorders !== rootWindow.hikvisionRecordersJson) {
                console.log("[Sync] Live-reloading NVR Recorders list...");
                rootWindow.hikvisionRecordersJson = openedRecorders;
            } else if (rootWindow.recordersSecretsReady) {
                var sealedRecorders = RecorderSecrets.seal(openedRecorders, Context.config.fileName);
                if (sealedRecorders !== "" && sealedRecorders !== hikvisionSettings.recordersJson) {
                    rootWindow.recordersSealing = true;
                    hikvisionSettings.recordersJson = sealedRecorders;
                    rootWindow.recordersSealing = false;
                }
            }

            // 2. Check and live-reload Viewport Layouts definitions
            var diskModels = Context.readSetting("ViewportsLayoutsCollection", "models", "");
            if (diskModels !== "") {
                if (diskModels === rootWindow.lastSavedModelsJson) {
                    // Disk has caught up to our latest save, or we are in sync.
                    rootWindow.lastLoadedModelsJson = diskModels;
                } else if (diskModels === rootWindow.lastLoadedModelsJson) {
                    // Disk is still showing the old state before our latest save. Ignore it.
                } else {
                    // External change!
                    console.log("[Sync] Live-reloading Viewports Layouts list due to external change...");
                    saveTimer.stop();
                    rootWindow.lastLoadedModelsJson = diskModels;
                    rootWindow.lastSavedModelsJson = diskModels;
                    layoutsCollectionSettings.models = diskModels;
                    rootWindow.isSyncing = true;
                    try {
                        layoutsCollectionModel.fromJSValue(JSON.parse(diskModels));
                    } catch(e) {
                        console.log("[Sync] Error parsing updated layouts:", e);
                    } finally {
                        syncEndTimer.restart();
                    }
                }
            }

            // 3. Check and live-reload General Settings
            var diskSingleApp = Context.readSetting("", "singleApplication", true);
            if (generalSettings.singleApplication !== diskSingleApp) {
                generalSettings.singleApplication = diskSingleApp;
            }
            var diskAllowSwapping = Context.readSetting("", "allowSwappingViewports", true);
            if (generalSettings.allowSwappingViewports !== diskAllowSwapping) {
                generalSettings.allowSwappingViewports = diskAllowSwapping;
            }
            var diskEnableChangeViewport = Context.readSetting("", "enableChangeViewportSettings", true);
            if (generalSettings.enableChangeViewportSettings !== diskEnableChangeViewport) {
                generalSettings.enableChangeViewportSettings = diskEnableChangeViewport;
            }
            var diskEnableStreamSel = Context.readSetting("", "enableStreamSelection", true);
            if (generalSettings.enableStreamSelection !== diskEnableStreamSel) {
                generalSettings.enableStreamSelection = diskEnableStreamSel;
            }
            var rawSnapshotPath = Context.readSetting("", "snapshotPath", "");
            var diskSnapshotPath = Context.sanitizePlatformPath(rawSnapshotPath, Context.defaultPicturesPath());
            if (generalSettings.snapshotPath !== diskSnapshotPath) {
                generalSettings.snapshotPath = diskSnapshotPath;
            }
            var rawVideoPath = Context.readSetting("", "videoPath", "");
            var diskVideoPath = Context.sanitizePlatformPath(rawVideoPath, Context.defaultMoviesPath());
            if (generalSettings.videoPath !== diskVideoPath) {
                generalSettings.videoPath = diskVideoPath;
            }
            var diskEnableContextMenu = Context.readSetting("", "enableContextMenu", true);
            if (generalSettings.enableContextMenu !== diskEnableContextMenu) {
                generalSettings.enableContextMenu = diskEnableContextMenu;
            }
            var diskEnableRemoveCamera = Context.readSetting("", "enableRemoveCamera", true);
            if (generalSettings.enableRemoveCamera !== diskEnableRemoveCamera) {
                generalSettings.enableRemoveCamera = diskEnableRemoveCamera;
            }
            var diskLockGridSize = Context.readSetting("", "lockGridSize", false);
            if (generalSettings.lockGridSize !== diskLockGridSize) {
                generalSettings.lockGridSize = diskLockGridSize;
            }
            var diskAuxiliaryLimit = Context.readSetting("", "auxiliaryLimit", 1);
            if (diskAuxiliaryLimit < 0) diskAuxiliaryLimit = 0;
            if (diskAuxiliaryLimit > 3) diskAuxiliaryLimit = 3;
            if (generalSettings.auxiliaryLimit !== diskAuxiliaryLimit) {
                generalSettings.auxiliaryLimit = diskAuxiliaryLimit;
            }
            var diskAuxiliaryScale = String(Context.readSetting("", "auxiliaryScale", "1"));
            if (diskAuxiliaryScale !== "same" && diskAuxiliaryScale !== "1" && diskAuxiliaryScale !== "1.5" && diskAuxiliaryScale !== "2")
                diskAuxiliaryScale = "1";
            if (generalSettings.auxiliaryScale !== diskAuxiliaryScale) {
                generalSettings.auxiliaryScale = diskAuxiliaryScale;
            }
            var diskPlaybackOffsetSeconds = Context.readSetting("", "playbackOffsetSeconds", 120);
            if (generalSettings.playbackOffsetSeconds !== diskPlaybackOffsetSeconds) {
                generalSettings.playbackOffsetSeconds = diskPlaybackOffsetSeconds;
            }
            var diskPlaybackTimelineHours = Context.readSetting("", "playbackTimelineHours", 2);
            if (diskPlaybackTimelineHours < 1) diskPlaybackTimelineHours = 1;
            if (diskPlaybackTimelineHours > 24) diskPlaybackTimelineHours = 24;
            if (generalSettings.playbackTimelineHours !== diskPlaybackTimelineHours) {
                generalSettings.playbackTimelineHours = diskPlaybackTimelineHours;
            }
            var diskPauseLiveDuringPlayback = Context.readSetting("", "pauseLiveDuringPlayback", true);
            if (generalSettings.pauseLiveDuringPlayback !== diskPauseLiveDuringPlayback) {
                generalSettings.pauseLiveDuringPlayback = diskPauseLiveDuringPlayback;
            }
            var diskDisableAudio = Context.readSetting("", "disableAudio", false);
            if (generalSettings.disableAudio !== diskDisableAudio) {
                generalSettings.disableAudio = diskDisableAudio;
            }
            var diskTargetHold = parseInt(Context.readSetting("", "targetHoldSeconds", 10));
            if (!(diskTargetHold >= 3 && diskTargetHold <= 30)) diskTargetHold = 10;
            if (generalSettings.targetHoldSeconds !== diskTargetHold) {
                generalSettings.targetHoldSeconds = diskTargetHold;
            }
            var diskPictures = parseInt(Context.readSetting("", "picturesPerCamera", 100));
            if ([100, 500, 1000].indexOf(diskPictures) < 0) diskPictures = 100;
            if (generalSettings.picturesPerCamera !== diskPictures) {
                generalSettings.picturesPerCamera = diskPictures;
            }
            var diskTargetSource = String(Context.readSetting("", "targetSource", "camera"));
            if (diskTargetSource !== "camera" && diskTargetSource !== "recorder") diskTargetSource = "camera";
            if (generalSettings.targetSource !== diskTargetSource) {
                generalSettings.targetSource = diskTargetSource;
            }
            var diskLogDetections = Context.readSetting("", "logDetectionEvents", false);
            if (generalSettings.logDetectionEvents !== diskLogDetections) {
                generalSettings.logDetectionEvents = diskLogDetections;
            }
            var diskCheckSetup = Context.readSetting("", "checkSetupAtStart", false);
            if (generalSettings.checkSetupAtStart !== diskCheckSetup) {
                generalSettings.checkSetupAtStart = diskCheckSetup;
            }
            var diskOverlayText = String(Context.readSetting("", "overlayText", "{}"));
            if (generalSettings.overlayText !== diskOverlayText) {
                // A file watch can arrive while a restore is being written and still see the empty list. Do not put
                // that empty list back over entries that are already in memory.
                var diskEntries = 0;
                var memEntries = 0;
                try { diskEntries = (JSON.parse(diskOverlayText).entries || []).length; } catch (e1) {}
                try { memEntries = (JSON.parse(generalSettings.overlayText || "{}").entries || []).length; } catch (e2) {}
                if (!(diskEntries === 0 && memEntries > 0))
                    generalSettings.overlayText = diskOverlayText;
            }
            var diskTargetKinds = String(Context.readSetting("", "targetKinds", "motion,line,intrusion,enter,exit,face,other"));
            if (!Context.readSetting("", "targetKindsHasFace", false)) {
                // Once: a setting saved before the Face detection checkbox keeps face labels on (they used to follow "other").
                diskTargetKinds = Utils.kindsWithFace(diskTargetKinds);
                Context.writeSetting("", "targetKinds", diskTargetKinds);
                Context.writeSetting("", "targetKindsHasFace", true);
            }
            if (generalSettings.targetKinds !== diskTargetKinds) {
                generalSettings.targetKinds = diskTargetKinds;
            }
            var diskTargetTargets = String(Context.readSetting("", "targetTargets", "human,vehicle,animal,other"));
            if (generalSettings.targetTargets !== diskTargetTargets) {
                generalSettings.targetTargets = diskTargetTargets;
            }
            var diskLogMotion = Context.readSetting("", "logUnlabelledMotion", false);
            if (generalSettings.logUnlabelledMotion !== diskLogMotion) {
                generalSettings.logUnlabelledMotion = diskLogMotion;
            }
            var diskFrameMotion = Context.readSetting("", "frameUnlabelledMotion", false);
            if (generalSettings.frameUnlabelledMotion !== diskFrameMotion) {
                generalSettings.frameUnlabelledMotion = diskFrameMotion;
            }
            var diskSourceOverrides = String(Context.readSetting("", "targetSourceOverrides", "{}"));
            if (generalSettings.targetSourceOverrides !== diskSourceOverrides) {
                generalSettings.targetSourceOverrides = diskSourceOverrides;
            }
            var diskTargetNvrOn = String(Context.readSetting("", "targetNvrOnCameras", "[]"));
            if (generalSettings.targetNvrOnCameras !== diskTargetNvrOn) {
                generalSettings.targetNvrOnCameras = diskTargetNvrOn;
            }
            var diskTargetOff = String(Context.readSetting("", "targetOffCameras", "[]"));
            if (generalSettings.targetOffCameras !== diskTargetOff) {
                generalSettings.targetOffCameras = diskTargetOff;
            }
            var diskShowTarget = Context.readSetting("", "showTargetIndicator", false);
            if (generalSettings.showTargetIndicator !== diskShowTarget) {
                generalSettings.showTargetIndicator = diskShowTarget;
            }
            var diskWebBrowser = String(Context.readSetting("", "webBrowserChoice", ""));
            if (generalSettings.webBrowserChoice !== diskWebBrowser) {
                generalSettings.webBrowserChoice = diskWebBrowser;
            }
            var diskDisableTalk = Context.readSetting("", "disableTalk", false);
            if (generalSettings.disableTalk !== diskDisableTalk) {
                generalSettings.disableTalk = diskDisableTalk;
            }
            var diskTalkMicrophone = Context.readSetting("", "talkMicrophone", "");
            if (generalSettings.talkMicrophone !== diskTalkMicrophone) {
                generalSettings.talkMicrophone = diskTalkMicrophone;
            }
            var diskTalkGain = Number(Context.readSetting("", "talkGain", 2.0));
            if (!(diskTalkGain >= 0.5 && diskTalkGain <= 4)) diskTalkGain = 2.0;
            if (Math.abs(generalSettings.talkGain - diskTalkGain) > 0.001) {
                generalSettings.talkGain = diskTalkGain;
            }
            var diskTalkBoost = Number(Context.readSetting("", "talkBoostDb", 0.0));
            if (!(diskTalkBoost >= -6 && diskTalkBoost <= 12)) diskTalkBoost = 0.0;
            if (Math.abs(generalSettings.talkBoostDb - diskTalkBoost) > 0.001) {
                generalSettings.talkBoostDb = diskTalkBoost;
            }
            var diskEnableDiagnosticLogs = Context.readSetting("", "enableDiagnosticLogs", false);
            if (generalSettings.enableDiagnosticLogs !== diskEnableDiagnosticLogs) {
                generalSettings.enableDiagnosticLogs = diskEnableDiagnosticLogs;
            }
            if (!Context.isAuxiliary) {
                var diskCurrentIndex = Context.readSetting("MainLayout", "currentIndex", windowLayoutSettings.currentIndex);
                if (layoutsCollectionModel.count > 0) {
                    var clampedIdx = diskCurrentIndex.clamp(0, layoutsCollectionModel.count - 1);
                    if (windowLayoutSettings.currentIndex !== clampedIdx) {
                        windowLayoutSettings.currentIndex = clampedIdx;
                    }
                    if (stackLayout.currentIndex !== clampedIdx) {
                        stackLayout.currentIndex = clampedIdx;
                    }
                }
            }

            // 4. Check and live-reload View Settings
            var diskHideCursor = Context.readSetting("View", "hideCursorWhenFullScreen", true);
            if (viewSettings.hideCursorWhenFullScreen !== diskHideCursor) {
                viewSettings.hideCursorWhenFullScreen = diskHideCursor;
            }
            var diskHideCursorWindowed = Context.readSetting("View", "hideCursorWhenWindowed", true);
            if (viewSettings.hideCursorWhenWindowed !== diskHideCursorWindowed) {
                viewSettings.hideCursorWhenWindowed = diskHideCursorWindowed;
            }
            var diskShowChannelStatus = Context.readSetting("View", "showChannelStatus", true);
            if (viewSettings.showChannelStatus !== diskShowChannelStatus) {
                viewSettings.showChannelStatus = diskShowChannelStatus;
            }
            var diskShowChannelResolution = Context.readSetting("View", "showChannelResolution", false);
            if (viewSettings.showChannelResolution !== diskShowChannelResolution) {
                viewSettings.showChannelResolution = diskShowChannelResolution;
            }
            var diskHideInfoBadgesWhenIdle = Context.readSetting("View", "hideInfoBadgesWhenIdle", false);
            if (viewSettings.hideInfoBadgesWhenIdle !== diskHideInfoBadgesWhenIdle) {
                viewSettings.hideInfoBadgesWhenIdle = diskHideInfoBadgesWhenIdle;
            }
            var diskShowCameraInfo = Context.readSetting("View", "showCameraInfo", true);
            if (viewSettings.showCameraInfo !== diskShowCameraInfo) {
                viewSettings.showCameraInfo = diskShowCameraInfo;
            }
            var diskHoverControlIcons = Context.readSetting("View", "hoverControlIcons", true);
            if (viewSettings.hoverControlIcons !== diskHoverControlIcons) {
                viewSettings.hoverControlIcons = diskHoverControlIcons;
            }
            var diskShowInfoOnHoverOnly = Context.readSetting("View", "showInfoOnHoverOnly", false);
            if (viewSettings.showInfoOnHoverOnly !== diskShowInfoOnHoverOnly) {
                viewSettings.showInfoOnHoverOnly = diskShowInfoOnHoverOnly;
            }
            var diskShowTopBarByDefault = Context.readSetting("View", "showTopBarByDefault", true);
            if (viewSettings.showTopBarByDefault !== diskShowTopBarByDefault) {
                viewSettings.showTopBarByDefault = diskShowTopBarByDefault;
            }
            var diskNoUnmuteWhenFullScreen = Context.readSetting("Viewport", "noUnmuteWhenFullScreen", false);
            if (viewportSettings.noUnmuteWhenFullScreen !== diskNoUnmuteWhenFullScreen) {
                viewportSettings.noUnmuteWhenFullScreen = diskNoUnmuteWhenFullScreen;
            }
            var hasMigrated = Context.readSetting("ViewportsLayoutsCollection", "migratedLowLatencyFlags", false);
            var diskDefaultAVFormatOptions;
            
            if (!hasMigrated) {
                diskDefaultAVFormatOptions = Context.readSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", "{\"analyzeduration\":100000,\"probesize\":500000}");
                try {
                    var opts = JSON.parse(diskDefaultAVFormatOptions);
                    var needsMigration = false;
                    if (opts["fflags"] === undefined) {
                        opts["fflags"] = "+nobuffer";
                        needsMigration = true;
                    }
                    if (opts["flags"] === undefined) {
                        opts["flags"] = "low_delay";
                        needsMigration = true;
                    }
                    if (needsMigration) {
                        diskDefaultAVFormatOptions = JSON.stringify(opts);
                    }
                } catch(err) {
                    console.warn("Failed to migrate AV format options");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "migratedLowLatencyFlags", true);
            } else {
                var defaultStr = "{\"analyzeduration\":100000,\"probesize\":500000,\"fflags\":\"+nobuffer\",\"flags\":\"low_delay\",\"stimeout\":5000000,\"rtsp_transport\":\"tcp\"}";
                diskDefaultAVFormatOptions = Context.readSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", defaultStr);
            }
            
            var hasMigratedAnalyzeduration = Context.readSetting("ViewportsLayoutsCollection", "migratedAnalyzeduration100ms", false);
            if (!hasMigratedAnalyzeduration) {
                try {
                    var opts2 = JSON.parse(diskDefaultAVFormatOptions);
                    if (opts2["analyzeduration"] == 0) {
                        opts2["analyzeduration"] = 100000;
                        diskDefaultAVFormatOptions = JSON.stringify(opts2);
                        Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", diskDefaultAVFormatOptions);
                    }
                } catch(err) {
                    console.warn("Failed to migrate analyzeduration");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "migratedAnalyzeduration100ms", true);
            }

            var hasMigratedSTimeout = Context.readSetting("ViewportsLayoutsCollection", "migratedTimeout5s_v2", false);
            if (!hasMigratedSTimeout) {
                try {
                    var opts3 = JSON.parse(diskDefaultAVFormatOptions);
                    if (opts3["stimeout"] === undefined) {
                        opts3["stimeout"] = 5000000;
                    }
                    if (opts3["rw_timeout"] === undefined) {
                        opts3["rw_timeout"] = 5000000;
                    }
                    diskDefaultAVFormatOptions = JSON.stringify(opts3);
                    Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", diskDefaultAVFormatOptions);
                } catch(err) {
                    console.warn("Failed to migrate stimeout");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "migratedTimeout5s_v2", true);
            }

            // The saved socket timeout stays "stimeout". The player maps that name to the one
            // this build of FFmpeg uses. FFmpeg 4.4 treats a key named "timeout" as listen mode.
            var hasRemovedRtspListenTimeout = Context.readSetting("ViewportsLayoutsCollection", "removedRtspListenTimeout", false);
            if (!hasRemovedRtspListenTimeout) {
                try {
                    var optsListen = JSON.parse(diskDefaultAVFormatOptions);
                    if (optsListen["timeout"] !== undefined) {
                        delete optsListen["timeout"];
                        diskDefaultAVFormatOptions = JSON.stringify(optsListen);
                        Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", diskDefaultAVFormatOptions);
                    }
                } catch(err) {
                    console.warn("Failed to remove RTSP listen timeout");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "removedRtspListenTimeout", true);
            }

            var hasMigratedRtspTcp = Context.readSetting("ViewportsLayoutsCollection", "migratedRtspTcp", false);
            if (!hasMigratedRtspTcp) {
                try {
                    var opts4 = JSON.parse(diskDefaultAVFormatOptions);
                    if (opts4["rtsp_transport"] === undefined) {
                        opts4["rtsp_transport"] = "tcp";
                    }
                    diskDefaultAVFormatOptions = JSON.stringify(opts4);
                    Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", diskDefaultAVFormatOptions);
                } catch(err) {
                    console.warn("Failed to migrate rtsp_transport");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "migratedRtspTcp", true);
            }

            // "nobuffer" alone replaces every demuxer flag, including the default autobsf bit.
            // "+nobuffer" adds the no-buffer flag and leaves the others in place.
            var hasMigratedNobufferPlus = Context.readSetting("ViewportsLayoutsCollection", "migratedFflagsNobufferPlus", false);
            if (!hasMigratedNobufferPlus) {
                try {
                    var optsNobuffer = JSON.parse(diskDefaultAVFormatOptions);
                    if (optsNobuffer["fflags"] === "nobuffer") {
                        optsNobuffer["fflags"] = "+nobuffer";
                        diskDefaultAVFormatOptions = JSON.stringify(optsNobuffer);
                        Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", diskDefaultAVFormatOptions);
                    }
                } catch(err) {
                    console.warn("Failed to migrate fflags nobuffer");
                }
                Context.writeSetting("ViewportsLayoutsCollection", "migratedFflagsNobufferPlus", true);
            }

            if (layoutsCollectionSettings.defaultAVFormatOptions !== diskDefaultAVFormatOptions) {
                layoutsCollectionSettings.defaultAVFormatOptions = diskDefaultAVFormatOptions;
            }
            var diskDisableViewportZoomAnimation = Context.readSetting("View", "disableViewportZoomAnimation", false);
            if (viewSettings.disableViewportZoomAnimation !== diskDisableViewportZoomAnimation) {
                viewSettings.disableViewportZoomAnimation = diskDisableViewportZoomAnimation;
            }


            // 6. Check and live-reload Application Language
            var diskLang = Context.readSetting("", "language", "system");
            if (Context.getLanguage() !== diskLang) {
                console.log("[Sync] Live-reloading language to:", diskLang);
                Context.setLanguage(diskLang);
            }

            // 7. Live-reload NVR Status Manager settings
            NvrStatusManager.reloadSettings();
        }
    }

    Settings {
        id: layoutsCollectionSettings

        fileName: Context.config.fileName
        category: "ViewportsLayoutsCollection"

        property string models
        property string defaultAVFormatOptions: "{\"analyzeduration\":100000,\"probesize\":500000,\"fflags\":\"+nobuffer\",\"flags\":\"low_delay\",\"stimeout\":5000000,\"rtsp_transport\":\"tcp\"}"

        function toJSValue(key) {
            var obj = {};

            try {
                obj = JSON.parse(layoutsCollectionSettings[String(key)]);
            } catch(err) {
                Utils.log_error(qsTr("LNG_00219"));
            }

            return obj;
        }
    }

    Settings {
        id: viewSettings

        fileName: Context.config.fileName
        category: "View"

        property bool hideCursorWhenFullScreen: true
        property bool hideCursorWhenWindowed: true
        property bool showChannelStatus: true
        property bool showChannelResolution: false
        property bool hideInfoBadgesWhenIdle: false
        property bool showCameraInfo: true
        property bool hoverControlIcons: true
        property bool showInfoOnHoverOnly: false
        property bool showTopBarByDefault: true
        property bool disableViewportZoomAnimation: false
    }

    Settings {
        id: viewportSettings

        fileName: Context.config.fileName
        category: "Viewport"

        property bool noUnmuteWhenFullScreen: false
    }

    Shortcut {
        sequence: "M"
        onActivated: {
            var layout = Utils.currentLayout();
            if (layout && layout.focusIndex >= 0)
                layout.toggleTileMute(layout.focusIndex);
        }
    }
    Shortcut {
        sequence: "Alt+Right"
        onActivated: stackLayout.currentIndex = Math.min(stackLayout.currentIndex + 1, stackLayout.count - 1)
    }
    Shortcut {
        sequence: "Alt+Left"
        onActivated: stackLayout.currentIndex = Math.max(stackLayout.currentIndex - 1, 0)
    }
    // Shortcuts for the first 9 presets (Alt + 1, Alt + 2, ..., Alt + 9)
    Repeater {
        model: Context.config.kioskMode ? 0 : Math.min(stackLayout.count, 9)

        Item {
            Shortcut {
                sequence: "Alt+" + (index + 1)
                onActivated: stackLayout.currentIndex = index
            }
        }
    }
    Shortcut {
        sequences: ["F11", StandardKey.FullScreen]
        onActivated: toggleFullScreen()
        onActivatedAmbiguously: toggleFullScreen()

        function toggleFullScreen() {
            Context.config.fullScreen = !Context.config.fullScreen;
        }
    }
    Shortcut {
        sequence: StandardKey.Quit
        onActivated: Qt.quit()
    }

    Shortcut {
        sequence: "Ctrl+N"
        onActivated: rootWindow.openAuxiliaryWindow()
    }

    function setRootWindowRatio(ratio) {
        var horzRatio = Utils.currentModel().size.width * ratio.width;
        var vertRatio = Utils.currentModel().size.height * ratio.height;
        var pixels = Math.round(rootWindow.width / horzRatio);

        if (!Context.config.fullScreen) {
            rootWindow.width = horzRatio * pixels;
            rootWindow.height = vertRatio * pixels;
        }
    }

    function openAuxiliaryWindow(initialState) {
        loadingTimer.start();
        Context.startAuxiliaryProcess();
    }

    function openPlaybackWindow(recInfo, channelId, cameraName, startMs) {
        var at = startMs > 0 ? startMs : 0;
        if (playbackWindowLoader.active) {
            if (playbackWindowLoader.item) {
                if (at > 0) {
                    // Already open: show the camera at that moment in the window as it is.
                    playbackWindowLoader.item.openCameraAt(recInfo, { "channelId": channelId, "name": cameraName }, at);
                } else {
                    playbackWindowLoader.item.recorderInfo = recInfo;
                    playbackWindowLoader.item.channelId = channelId;
                    playbackWindowLoader.item.cameraName = cameraName;
                }
                playbackWindowLoader.item.show();
                playbackWindowLoader.item.raise();
            }
        } else {
            playbackWindowLoader.setSource("qrc:/src/PlaybackWindow.qml", {
                "recorderInfo": recInfo,
                "channelId": channelId,
                "cameraName": cameraName,
                "initialStartMs": at,
                "width": rootWindow.width * 0.9,
                "height": rootWindow.height * 0.9
            });
            playbackWindowLoader.active = true;
        }
    }

    // Open playback for a recorder channel at a moment (epoch milliseconds), using the login saved for
    // that recorder. Used by the detection log. Returns false when the recorder is not in the saved list.
    function openPlaybackAt(recorderIp, channelId, startMs) {
        var list = [];
        try {
            list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]");
        } catch (e) {
            return false;
        }
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            if ((rec.ip || "").trim().split(":")[0] !== recorderIp)
                continue;
            var camName = "Camera " + channelId;
            var cams = rec.cameras || [];
            for (var j = 0; j < cams.length; ++j) {
                if (parseInt(cams[j].channelId) === channelId) {
                    camName = cams[j].customName || cams[j].name || camName;
                    break;
                }
            }
            var recInfo = {
                "ip": recorderIp,
                "name": rec.name || recorderIp,
                "port": rec.sdkPort || rec.port || 8000,
                "sdkPort": rec.sdkPort || rec.port || 8000,
                "httpPort": rec.httpPort || 80,
                "rtspPort": rec.rtspPort || 554,
                "username": rec.username,
                "password": rec.password
            };
            rootWindow.openPlaybackWindow(recInfo, channelId, camName, startMs);
            return true;
        }
        return false;
    }

    function openPlaybackWindowEmpty() {
        openPlaybackWindow(null, -1, "");
    }

    // Bumped when Camera Tools sets a camera's picture stream, so that window redraws its marks.
    property int tileStreamRev: 0

    // "ip#channel" for a hikvision:// tile address, or "" for anything else.
    function tileKeyFromUrl(url) {
        var s = String(url || "");
        var idx = s.indexOf("hikvision://");
        if (idx < 0)
            return "";
        var content = s.substring(idx + 12);
        var slash = content.indexOf("/");
        var main = slash >= 0 ? content.substring(0, slash) : content;
        var path = slash >= 0 ? content.substring(slash + 1) : "1";
        var at = main.lastIndexOf("@");
        var addr = at >= 0 ? main.substring(at + 1) : main;
        var ip = addr.split(":")[0];
        var ch = parseInt(path);
        if (ip === "" || isNaN(ch))
            return "";
        return ip + "#" + ch;
    }

    function tileStreamSaved(key) {
        if (!key)
            return 0;
        try {
            var o = JSON.parse(generalSettings.tileStreamByCamera || "{}");
            var m = o[key];
            if (m === 1 || m === 2 || m === 3)
                return m;
        } catch (e) {}
        return 0;
    }

    function layoutByUid(uid) {
        if (!uid)
            return null;
        for (var L = 0; L < layoutsCollectionModel.count; ++L) {
            var layout = layoutsCollectionModel.get(L);
            if (layout && layout.uid === uid)
                return layout;
        }
        return null;
    }

    function excludeList(layout) {
        if (!layout)
            return [];
        try {
            var l = JSON.parse(layout.streamExcludes || "[]");
            return Array.isArray(l) ? l : [];
        } catch (e) {
            return [];
        }
    }

    function layoutExcludes(layout, key) {
        return !!key && rootWindow.excludeList(layout).indexOf(key) >= 0;
    }

    function layoutUidExcludes(uid, key) {
        var rev = rootWindow.tileStreamRev;
        return rootWindow.layoutExcludes(rootWindow.layoutByUid(uid), key);
    }

    // What the tiles that follow this camera are using. 1 Main, 2 Sub, 3 Third, 0 Auto,
    // -1 when those layouts do not agree. An excluded layout is left out of this.
    function cameraStreamMode(key) {
        var rev = rootWindow.tileStreamRev;
        if (!key)
            return 0;
        var seen = -2;
        for (var L = 0; L < layoutsCollectionModel.count; ++L) {
            var layout = layoutsCollectionModel.get(L);
            if (!layout || layout === rootWindow.scratchLayout || rootWindow.layoutExcludes(layout, key))
                continue;
            for (var v = 0; v < layout.count; ++v) {
                var item = layout.get(v);
                if (!item || rootWindow.tileKeyFromUrl(item.url) !== key)
                    continue;
                if (seen === -2)
                    seen = item.streamMode;
                else if (seen !== item.streamMode)
                    return -1;
            }
        }
        if (seen === -2)
            return rootWindow.tileStreamSaved(key);
        return seen;
    }

    function applyStreamToLayout(layout, key, mode) {
        if (!layout)
            return;
        for (var v = 0; v < layout.count; ++v) {
            var item = layout.get(v);
            if (!item || rootWindow.tileKeyFromUrl(item.url) !== key)
                continue;
            if (item.streamMode !== mode)
                item.streamMode = mode;
        }
    }

    // Save one camera's stream on one layout. Auto clears Exclude. Main, Sub, and Third mark it.
    function setLayoutCameraStream(layout, key, mode) {
        if (!layout || !key)
            return;
        if (mode !== 0 && mode !== 1 && mode !== 2 && mode !== 3)
            return;
        rootWindow.applyStreamToLayout(layout, key, mode);
        if (mode === 0)
            rootWindow.releaseCameraOnLayout(layout, key);
        else
            rootWindow.excludeCameraOnLayout(layout, key);
        rootWindow.tileStreamRev++;
    }

    // Remember the choice and write it onto every tile of these cameras that is not excluded.
    // 0 is Auto: the entry is forgotten and every following tile of that camera goes back to Auto.
    function setCameraStream(keys, mode) {
        if (mode !== 0 && mode !== 1 && mode !== 2 && mode !== 3)
            return;
        var o = {};
        try { o = JSON.parse(generalSettings.tileStreamByCamera || "{}"); } catch (e) {}
        if (!o || typeof o !== "object" || Array.isArray(o))
            o = {};
        for (var i = 0; i < keys.length; ++i) {
            if (mode === 0)
                delete o[keys[i]];
            else
                o[keys[i]] = mode;
        }
        generalSettings.tileStreamByCamera = JSON.stringify(o);
        for (var L = 0; L < layoutsCollectionModel.count; ++L) {
            var layout = layoutsCollectionModel.get(L);
            if (!layout || layout === rootWindow.scratchLayout)
                continue;
            for (var k = 0; k < keys.length; ++k) {
                if (!rootWindow.layoutExcludes(layout, keys[k]))
                    rootWindow.applyStreamToLayout(layout, keys[k], mode);
            }
        }
        rootWindow.tileStreamRev++;
    }

    // True when this layout has a Main, Sub, or Third tile for the camera.
    // Auto, and a layout that does not show the camera, are not exceptions.
    function layoutHasNonAuto(layout, key) {
        if (!layout || !key)
            return false;
        for (var v = 0; v < layout.count; ++v) {
            var item = layout.get(v);
            if (!item || rootWindow.tileKeyFromUrl(item.url) !== key)
                continue;
            if (item.streamMode === 1 || item.streamMode === 2 || item.streamMode === 3)
                return true;
        }
        return false;
    }

    // A right-click of Main, Sub, or Third marks that layout so the camera-wide choice leaves it alone.
    function excludeCameraOnLayout(layout, key) {
        if (!layout || !key || rootWindow.layoutExcludes(layout, key))
            return;
        var l = rootWindow.excludeList(layout);
        l.push(key);
        layout.streamExcludes = JSON.stringify(l);
        rootWindow.tileStreamRev++;
    }

    // Auto is the default, so it is not an exception. Drop the flag and leave the saved Auto in place.
    function releaseCameraOnLayout(layout, key) {
        if (!layout || !key || !rootWindow.layoutExcludes(layout, key))
            return;
        var l = rootWindow.excludeList(layout);
        var at = l.indexOf(key);
        if (at < 0)
            return;
        l.splice(at, 1);
        layout.streamExcludes = JSON.stringify(l);
        rootWindow.tileStreamRev++;
    }

    // Drop exclude entries whose tiles on that layout are all Auto. Does not change the saved stream.
    function clearAutoExcludes() {
        var changed = false;
        for (var L = 0; L < layoutsCollectionModel.count; ++L) {
            var layout = layoutsCollectionModel.get(L);
            if (!layout || layout === rootWindow.scratchLayout)
                continue;
            var list = rootWindow.excludeList(layout);
            var kept = [];
            for (var i = 0; i < list.length; ++i) {
                if (rootWindow.layoutHasNonAuto(layout, list[i]))
                    kept.push(list[i]);
            }
            if (kept.length !== list.length) {
                layout.streamExcludes = JSON.stringify(kept);
                changed = true;
            }
        }
        if (changed)
            rootWindow.tileStreamRev++;
        return changed;
    }

    // Tick or clear Exclude for one camera on one layout.
    // Auto cannot be ticked. Clearing a Main, Sub, or Third tile makes it follow the camera-wide choice again.
    function setLayoutExcluded(uid, key, on) {
        var layout = rootWindow.layoutByUid(uid);
        if (!layout || !key)
            return;
        if (on && !rootWindow.layoutHasNonAuto(layout, key))
            return;
        var mode = rootWindow.cameraStreamMode(key);
        if (mode !== 0 && mode !== 1 && mode !== 2 && mode !== 3)
            mode = rootWindow.tileStreamSaved(key);
        var l = rootWindow.excludeList(layout);
        var at = l.indexOf(key);
        if (on && at < 0)
            l.push(key);
        else if (!on && at >= 0)
            l.splice(at, 1);
        else
            return;
        layout.streamExcludes = JSON.stringify(l);
        if (!on && rootWindow.layoutHasNonAuto(layout, key))
            rootWindow.applyStreamToLayout(layout, key, mode);
        rootWindow.tileStreamRev++;
    }

    // The stream a newly placed tile should start on: the remembered choice, or Auto.
    function streamModeForUrl(url) {
        return rootWindow.tileStreamSaved(rootWindow.tileKeyFromUrl(url));
    }

    // A camera placed where that layout did not already show it follows the camera choice, so a stale Exclude is cleared.
    function noteCameraPlaced(layout, url) {
        var key = rootWindow.tileKeyFromUrl(url);
        if (!layout || !key)
            return;
        var n = 0;
        for (var v = 0; v < layout.count; ++v) {
            var item = layout.get(v);
            if (item && rootWindow.tileKeyFromUrl(item.url) === key)
                n++;
        }
        if (n !== 1)
            return;
        var l = rootWindow.excludeList(layout);
        var at = l.indexOf(key);
        if (at < 0)
            return;
        l.splice(at, 1);
        layout.streamExcludes = JSON.stringify(l);
        rootWindow.tileStreamRev++;
    }

    property int savedLayoutIndex: -1
    property var scratchLayout: null

    function persistedLayoutsJson() {
        var models = layoutsCollectionModel.toJSValue();
        if (scratchLayout) {
            for (var i = models.length - 1; i >= 0; --i) {
                if (layoutsCollectionModel.get(i) === scratchLayout) {
                    models.splice(i, 1);
                    break;
                }
            }
        }
        return JSON.stringify(models);
    }

    function showScratchGrid(columns, rows) {
        if (!scratchLayout) {
            scratchLayout = layoutsCollectionModel.append();
            scratchLayout.visible = false;
            scratchLayout.name = "";
            scratchLayout.size = Qt.size(columns, rows);
        } else if (scratchLayout.size.width !== columns || scratchLayout.size.height !== rows) {
            scratchLayout.size = Qt.size(columns, rows);
        }
        var index = -1;
        for (var i = 0; i < layoutsCollectionModel.count; ++i) {
            if (layoutsCollectionModel.get(i) === scratchLayout) {
                index = i;
                break;
            }
        }
        if (index < 0) return;
        if (stackLayout.currentIndex !== index) {
            savedLayoutIndex = stackLayout.currentIndex;
        }
        stackLayout.currentIndex = index;
    }

    ViewportsLayoutsCollectionModel {
        id: layoutsCollectionModel

        // Demo group
        ViewportsLayoutModel {
            size: Qt.size(2, 2)
        }
        ViewportsLayoutModel {
            size: Qt.size(3, 3)
        }
        ViewportsLayoutModel {
            size: Qt.size(1, 1)
        }

        onCountChanged: stackLayout.currentIndex = stackLayout.currentIndex.clamp(0, layoutsCollectionModel.count - 1)
        Component.onCompleted: {
            // First-run pictures, only used when no layout has been saved yet. Both are public road cameras
            // published for anyone to view: a Norwegian highway camera, and a Minnesota highway camera.
            get(0).get(0).url = "https://kamera.vegvesen.no/public/1029002_1/manifest.m3u8";
            get(0).get(1).url = "https://video.dot.state.mn.us/public/C30083.stream/playlist.m3u8";

            var initialModels = "";
            var needsUid = false;
            rootWindow.isSyncing = true;
            try {
                if (!layoutsCollectionSettings.models.isEmpty()) {
                    initialModels = layoutsCollectionSettings.models;
                    var parsedModels = JSON.parse(initialModels);
                    
                    // Migrate hikvision URLs to strip credentials and port
                    for (var i = 0; i < parsedModels.length; i++) {
                        var model = parsedModels[i];
                        if (!model.uid) needsUid = true; // a layout saved before layouts had an id: it gets one, which must be saved
                        if (model.items) {
                            for (var j = 0; j < model.items.length; j++) {
                                var item = model.items[j];
                                ["url", "secondaryUrl"].forEach(function(prop) {
                                    if (item[prop] && item[prop].indexOf("hikvision://") === 0) {
                                        var uri = item[prop];
                                        var content = uri.substring(12);
                                        var chanIdx = content.indexOf("/");
                                        var chanId = chanIdx !== -1 ? content.substring(chanIdx) : "/1";
                                        var addrPart = content.substring(0, chanIdx !== -1 ? chanIdx : content.length);
                                        var ipPort = addrPart.split("@").pop().split(":");
                                        var ip = ipPort[0] || "";
                                        item[prop] = "hikvision://" + ip + chanId;
                                    }
                                });
                            }
                        }
                    }
                    
                    fromJSValue(parsedModels);
                }
            } catch(err) {
                Utils.log_error(qsTr("LNG_00219"));
            } finally {
                rootWindow.isSyncing = false;
            }
            if (!Context.isAuxiliary && rootWindow.clearAutoExcludes())
                saveTimer.restart();
            rootWindow.lastLoadedModelsJson = initialModels;
            rootWindow.lastSavedModelsJson = initialModels;

            layoutsCollectionModel.changed.connect(function () {
                if (rootWindow.isSyncing) return;
                rootWindow.refreshToolbarLayouts();
                saveTimer.restart();
            });
            rootWindow.refreshToolbarLayouts();
            if (needsUid && !Context.isAuxiliary)
                saveTimer.restart();

            if (Context.isAuxiliary) {
                stackLayout.currentIndex = -1;
            } else {
                // Force initialize "currentIndex" if option "-p" is set
                var currentIndex = (Context.config.currentIndex >= 0) ? Context.config.currentIndex : windowLayoutSettings.currentIndex;
                stackLayout.currentIndex = currentIndex.clamp(0, layoutsCollectionModel.count - 1);
            }
        }
    }

    // Hover area at the very top edge of the window to slide down the top bar
    MouseArea {
        id: hoverArea
        height: rootWindow.toolbarPx(12)
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        hoverEnabled: true
        z: 99999
        onContainsMouseChanged: {
            if (containsMouse) {
                keepVisibleTimer.stop();
            } else if (!topToolBarMouseArea.containsMouse) {
                keepVisibleTimer.start();
            }
        }
    }

    // Sleek premium horizontal top bar for settings and grid layout options (DOCK)
    Rectangle {
        id: topToolBar
        height: rootWindow.toolbarPx(56)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        color: (rootWindow.visibility === Window.FullScreen) ? "#44121214" : "#99121214"
        z: 9999
        radius: rootWindow.toolbarPx(12)

        // Slides down to y: -12 so that the top 12px (containing top rounded corners) is off-screen,
        // leaving only the bottom rounded corners visible at the top edge of the window.
        y: (!rootWindow.topBarAutoCollapse || hoverArea.containsMouse || topToolBarMouseArea.containsMouse || keepVisibleTimer.running) ? -rootWindow.toolbarPx(12) : -height

        Behavior on y {
            NumberAnimation {
                duration: 200
                easing.type: Easing.OutCubic
            }
        }

        MouseArea {
            id: topToolBarMouseArea
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: rootWindow.toolbarPx(44)
            hoverEnabled: true
            onContainsMouseChanged: {
                if (containsMouse) {
                    keepVisibleTimer.stop();
                } else if (!hoverArea.containsMouse) {
                    keepVisibleTimer.start();
                }
            }

            RowLayout {
                id: topRowLayout
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: rootWindow.toolbarPx(12)
                anchors.rightMargin: rootWindow.toolbarPx(12)
                height: rootWindow.toolbarPx(44)
                spacing: rootWindow.toolbarPx(6)

            Button {
                id: quitButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Text {
                    text: "✕"
                    font.bold: true
                    font.pixelSize: rootWindow.toolbarPx(14)
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                background: Rectangle {
                    color: quitButton.pressed ? "#cc2929" : (quitButton.hovered ? "#ff4d4d" : "#d63333")
                    radius: rootWindow.toolbarPx(15)
                }

                onClicked: {
                    quitConfirmDialog.open();
                }
            }

            Button {
                id: pinButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                property bool isPinned: !rootWindow.topBarAutoCollapse

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    rotation: pinButton.isPinned ? 0 : -45

                    Behavior on rotation {
                        NumberAnimation { duration: 150; easing.type: Easing.InOutQuad }
                    }

                    source: {
                        var colorStr = pinButton.hovered ? "white" : "%238898a6";
                        if (pinButton.isPinned) {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='" + colorStr + "' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='12' x2='12' y1='17' y2='22'></line><path d='M5 17h14v-1.76a2 2 0 0 0-.44-1.24l-2.78-3.56A2 2 0 0 1 15 9.2V5a2 2 0 0 0-2-2h-2a2 2 0 0 0-2 2v4.2a2 2 0 0 1-.78 1.24L5.44 14a2 2 0 0 0-.44 1.24Z'></path></svg>";
                        } else {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='12' x2='12' y1='17' y2='22'></line><path d='M5 17h14v-1.76a2 2 0 0 0-.44-1.24l-2.78-3.56A2 2 0 0 1 15 9.2V5a2 2 0 0 0-2-2h-2a2 2 0 0 0-2 2v4.2a2 2 0 0 1-.78 1.24L5.44 14a2 2 0 0 0-.44 1.24Z'></path></svg>";
                        }
                    }
                }

                background: Rectangle {
                    color: pinButton.pressed ? "#cc121214" : (pinButton.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: pinButton.hovered ? "#8898a6" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    rootWindow.topBarAutoCollapse = !rootWindow.topBarAutoCollapse;
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: pinButton.hovered
                ToolTip.text: pinButton.isPinned ? qsTr("LNG_00120") : qsTr("LNG_00119")
            }

            Button {
                id: fullScreenBtn
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                property bool isActive: Context.config.fullScreen

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    source: {
                        var colorStr = fullScreenBtn.hovered ? "%2300ff66" : (fullScreenBtn.isActive ? "%2300ff66" : "%2300cc52");
                        if (fullScreenBtn.isActive) {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='m14 10 7-7m-7 7h6m-6 0V4M10 14 3 21m7-7H4m6 0v6M14 14l7 7m-7-7v6m0-6h6M10 10 3 3m7 7V4m0 6H4'></path></svg>";
                        } else {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='m21 21-6-6m6 6V15m0 6h-6M3 3l6 6M3 3v6M3 3h6M3 21l6-6M3 21v-6M3 21h6M21 3l-6 6M21 3v6M21 3h-6'></path></svg>";
                        }
                    }
                }

                background: Rectangle {
                    color: fullScreenBtn.pressed ? "#cc121214" : (fullScreenBtn.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: fullScreenBtn.hovered ? "#00ff66" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    Context.config.fullScreen = !Context.config.fullScreen;
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: fullScreenBtn.hovered
                ToolTip.text: qsTr("LNG_00011")
            }

            Button {
                id: minimizeButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    source: {
                        var colorStr = minimizeButton.hovered ? "%2333ccff" : "%2300c8ff";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><line x1='5' y1='18' x2='19' y2='18'></line></svg>";
                    }
                }

                background: Rectangle {
                    color: minimizeButton.pressed ? "#cc121214" : (minimizeButton.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: minimizeButton.hovered ? "#00c8ff" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    rootWindow.showMinimized();
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: minimizeButton.hovered
                ToolTip.text: qsTr("LNG_00218")
            }

            Button {
                id: optionsButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    sourceSize.width: rootWindow.toolbarPx(16)
                    sourceSize.height: rootWindow.toolbarPx(16)
                    fillMode: Image.PreserveAspectFit
                    source: {
                        var colorStr = optionsButton.hovered ? "%23ff9e00" : "%23ff7a00";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><circle cx='12' cy='12' r='3'></circle><path d='M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z'></path></svg>";
                    }
                }

                background: Rectangle {
                    color: optionsButton.pressed ? "#cc121214" : (optionsButton.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: optionsButton.hovered ? "#ff9e00" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    sidebarWindow.visible = !sidebarWindow.visible;
                    if (sidebarWindow.visible) {
                        sidebarWindow.raise();
                        sidebarWindow.requestActivate();
                    }
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: optionsButton.hovered
                ToolTip.text: qsTr("LNG_00015")
            }

            Button {
                id: newWindowButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    sourceSize.width: rootWindow.toolbarPx(16)
                    sourceSize.height: rootWindow.toolbarPx(16)
                    fillMode: Image.PreserveAspectFit
                    source: {
                        var colorStr = newWindowButton.hovered ? "%23c084fc" : "%23a855f7";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='3' width='14' height='12' rx='2' ry='2'></rect><path d='M8 21h8'></path><path d='M12 17v4'></path><path d='M22 8v10a2 2 0 0 1-2 2H10'></path></svg>";
                    }
                }

                background: Rectangle {
                    color: newWindowButton.pressed ? "#cc121214" : (newWindowButton.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: newWindowButton.hovered ? "#c084fc" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    rootWindow.openAuxiliaryWindow();
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: newWindowButton.hovered
                ToolTip.text: qsTr("LNG_00014")
            }

            Button {
                id: archiveButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    sourceSize.width: rootWindow.toolbarPx(16)
                    sourceSize.height: rootWindow.toolbarPx(16)
                    fillMode: Image.PreserveAspectFit
                    source: {
                        var colorStr = "%23121214";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><ellipse cx='12' cy='5' rx='9' ry='3'></ellipse><path d='M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5'></path><path d='M3 12c0 1.66 4 3 9 3s9-1.34 9-3'></path></svg>";
                    }
                }

                background: Rectangle {
                    color: archiveButton.pressed ? "#00ccb0" : (archiveButton.hovered ? "#00ffd8" : "#00f5d4")
                    radius: rootWindow.toolbarPx(15)
                    border.color: archiveButton.pressed ? "#00ccb0" : (archiveButton.hovered ? "#00ffd8" : "#00f5d4")
                    border.width: 1
                }

                onClicked: {
                    rootWindow.openPlaybackWindowEmpty();
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: archiveButton.hovered
                ToolTip.text: qsTr("LNG_00217")
            }

            Button {
                id: instructionsButton
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    sourceSize.width: rootWindow.toolbarPx(16)
                    sourceSize.height: rootWindow.toolbarPx(16)
                    fillMode: Image.PreserveAspectFit
                    source: {
                        var colorStr = instructionsButton.hovered ? "%23facc15" : "%23eab308";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z'></path><path d='M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z'></path></svg>";
                    }
                }

                background: Rectangle {
                    color: instructionsButton.pressed ? "#cc121214" : (instructionsButton.hovered ? "#3a4550" : "#1c242c")
                    radius: rootWindow.toolbarPx(15)
                    border.color: instructionsButton.hovered ? "#facc15" : "#2a3540"
                    border.width: 1
                }

                onClicked: {
                    instructionsWindow.show();
                    instructionsWindow.raise();
                    instructionsWindow.requestActivate();
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: instructionsButton.hovered
                ToolTip.text: qsTr("LNG_00013")
            }

            Button {
                id: systemStatsSwitch
                checkable: true
                checked: false
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Image {
                    anchors.centerIn: parent
                    width: rootWindow.toolbarPx(16)
                    height: rootWindow.toolbarPx(16)
                    source: {
                        var colorStr = systemStatsSwitch.pressed ? "%23ffffff" : (systemStatsSwitch.checked ? "%2300ff66" : (systemStatsSwitch.hovered ? "%23ffffff" : "%238898a6"));
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><line x1='18' y1='20' x2='18' y2='10'></line><line x1='12' y1='20' x2='12' y2='4'></line><line x1='6' y1='20' x2='6' y2='14'></line></svg>";
                    }
                }

                background: Rectangle {
                    color: systemStatsSwitch.pressed ? "#cc121214" : (systemStatsSwitch.checked ? "#cc004d1a" : (systemStatsSwitch.hovered ? "#3a4550" : "#1c242c"))
                    radius: rootWindow.toolbarPx(15)
                    border.color: systemStatsSwitch.checked ? "#00ff66" : (systemStatsSwitch.hovered ? "#8898a6" : "#2a3540")
                    border.width: 1
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: systemStatsSwitch.hovered
                ToolTip.text: systemStatsSwitch.checked ? qsTr("LNG_00216") : qsTr("LNG_00215")
            }

            Button {
                id: nvrStatusButton
                visible: NvrStatusManager.monitoringEnabled && NvrStatusManager.hasConfiguredRecorders
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Item {
                    anchors.fill: parent

                    // Pulsing glow background when there are errors (Outer large wave)
                    Rectangle {
                        id: pulseGlow
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(30)
                        height: rootWindow.toolbarPx(30)
                        radius: rootWindow.toolbarPx(15)
                        color: "#ef4444"
                        opacity: 0.0
                        visible: NvrStatusManager.hasErrors

                        SequentialAnimation on scale {
                            running: NvrStatusManager.hasErrors
                            loops: Animation.Infinite
                            PropertyAnimation { from: 1.0; to: 2.3; duration: 800; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 2.3; to: 1.0; duration: 800; easing.type: Easing.InQuad }
                        }

                        SequentialAnimation on opacity {
                            running: NvrStatusManager.hasErrors
                            loops: Animation.Infinite
                            PropertyAnimation { from: 0.85; to: 0.0; duration: 800; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 0.0; to: 0.85; duration: 800; easing.type: Easing.InQuad }
                        }
                    }

                    // Secondary pulsing glow (Inner fast ripple)
                    Rectangle {
                        id: pulseGlowInner
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(30)
                        height: rootWindow.toolbarPx(30)
                        radius: rootWindow.toolbarPx(15)
                        color: "#ef4444"
                        opacity: 0.0
                        visible: NvrStatusManager.hasErrors

                        SequentialAnimation on scale {
                            running: NvrStatusManager.hasErrors
                            loops: Animation.Infinite
                            PropertyAnimation { from: 1.0; to: 1.6; duration: 600; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 1.6; to: 1.0; duration: 600; easing.type: Easing.InQuad }
                        }

                        SequentialAnimation on opacity {
                            running: NvrStatusManager.hasErrors
                            loops: Animation.Infinite
                            PropertyAnimation { from: 0.6; to: 0.1; duration: 600; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 0.1; to: 0.6; duration: 600; easing.type: Easing.InQuad }
                        }
                    }

                    Image {
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(16)
                        height: rootWindow.toolbarPx(16)
                        sourceSize.width: rootWindow.toolbarPx(16)
                        sourceSize.height: rootWindow.toolbarPx(16)
                        fillMode: Image.PreserveAspectFit
                        source: {
                            var colorStr = "%23121214";
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='2' width='20' height='8' rx='2' ry='2'></rect><rect x='2' y='14' width='20' height='8' rx='2' ry='2'></rect><line x1='6' y1='6' x2='6.01' y2='6'></line><line x1='6' y1='18' x2='6.01' y2='18'></line></svg>";
                        }
                    }
                }

                background: Rectangle {
                    color: {
                        if (NvrStatusManager.hasErrors) {
                            return nvrStatusButton.pressed ? "#b91c1c" : (nvrStatusButton.hovered ? "#ef4444" : "#dc2626");
                        } else {
                            return nvrStatusButton.pressed ? "#15803d" : (nvrStatusButton.hovered ? "#22c55e" : "#16a34a");
                        }
                    }
                    radius: rootWindow.toolbarPx(15)
                    border.color: NvrStatusManager.hasErrors ? "#ef4444" : "#22c55e"
                    border.width: 1
                }

                onClicked: {
                    nvrStatusDialog.open();
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: nvrStatusButton.hovered
                ToolTip.text: NvrStatusManager.hasErrors ? qsTr("LNG_00214") : qsTr("LNG_00213")
            }

            Button {
                id: bgLogButton
                visible: HikvisionEventLogger.backgroundMonitored
                Layout.preferredWidth: rootWindow.toolbarPx(30)
                Layout.preferredHeight: rootWindow.toolbarPx(30)
                Layout.alignment: Qt.AlignVCenter

                contentItem: Item {
                    anchors.fill: parent

                    Rectangle {
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(30)
                        height: rootWindow.toolbarPx(30)
                        radius: rootWindow.toolbarPx(15)
                        color: "#ef4444"
                        opacity: 0.0
                        visible: HikvisionEventLogger.backgroundProblem

                        SequentialAnimation on scale {
                            running: HikvisionEventLogger.backgroundProblem
                            loops: Animation.Infinite
                            PropertyAnimation { from: 1.0; to: 2.3; duration: 800; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 2.3; to: 1.0; duration: 800; easing.type: Easing.InQuad }
                        }
                        SequentialAnimation on opacity {
                            running: HikvisionEventLogger.backgroundProblem
                            loops: Animation.Infinite
                            PropertyAnimation { from: 0.85; to: 0.0; duration: 800; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 0.0; to: 0.85; duration: 800; easing.type: Easing.InQuad }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(30)
                        height: rootWindow.toolbarPx(30)
                        radius: rootWindow.toolbarPx(15)
                        color: "#ef4444"
                        opacity: 0.0
                        visible: HikvisionEventLogger.backgroundProblem

                        SequentialAnimation on scale {
                            running: HikvisionEventLogger.backgroundProblem
                            loops: Animation.Infinite
                            PropertyAnimation { from: 1.0; to: 1.6; duration: 600; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 1.6; to: 1.0; duration: 600; easing.type: Easing.InQuad }
                        }
                        SequentialAnimation on opacity {
                            running: HikvisionEventLogger.backgroundProblem
                            loops: Animation.Infinite
                            PropertyAnimation { from: 0.6; to: 0.1; duration: 600; easing.type: Easing.OutQuad }
                            PropertyAnimation { from: 0.1; to: 0.6; duration: 600; easing.type: Easing.InQuad }
                        }
                    }

                    Image {
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(16)
                        height: rootWindow.toolbarPx(16)
                        sourceSize.width: rootWindow.toolbarPx(16)
                        sourceSize.height: rootWindow.toolbarPx(16)
                        fillMode: Image.PreserveAspectFit
                        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='%23121214' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='22 12 18 12 15 21 9 3 6 12 2 12'></polyline></svg>"
                    }
                }

                background: Rectangle {
                    color: HikvisionEventLogger.backgroundProblem
                           ? (bgLogButton.pressed ? "#b91c1c" : (bgLogButton.hovered ? "#ef4444" : "#dc2626"))
                           : (bgLogButton.pressed ? "#15803d" : (bgLogButton.hovered ? "#22c55e" : "#16a34a"))
                    radius: rootWindow.toolbarPx(15)
                    border.color: HikvisionEventLogger.backgroundProblem ? "#ef4444" : "#22c55e"
                    border.width: 1
                }

                onClicked: bgLogMenu.popup(bgLogButton, 0, bgLogButton.height)

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: bgLogButton.hovered
                ToolTip.text: HikvisionEventLogger.backgroundText !== "" ? HikvisionEventLogger.backgroundText
                              : qsTr("Background detection logging")
            }

            Rectangle {
                width: 1
                height: rootWindow.toolbarPx(20)
                color: "#2a3540"
                Layout.alignment: Qt.AlignVCenter
                visible: nvrStatusButton.visible || bgLogButton.visible
            }

            RowLayout {
                spacing: rootWindow.toolbarPx(4)

                Switch {
                    id: lockGridSwitch
                    checked: generalSettings.lockGridSize

                    Layout.preferredHeight: rootWindow.toolbarPx(28)
                    Layout.alignment: Qt.AlignVCenter

                    indicator: Rectangle {
                        implicitWidth: rootWindow.toolbarPx(36)
                        implicitHeight: rootWindow.toolbarPx(18)
                        x: lockGridSwitch.leftPadding
                        y: parent.height / 2 - height / 2
                        radius: rootWindow.toolbarPx(9)
                        color: lockGridSwitch.checked ? "#ff7a00" : "#1c242c"
                        border.color: lockGridSwitch.checked ? "#ff9e00" : "#2a3540"
                        border.width: 1

                        Rectangle {
                            x: lockGridSwitch.checked ? parent.width - width - 2 : 2
                            y: 2
                            width: rootWindow.toolbarPx(14)
                            height: rootWindow.toolbarPx(14)
                            radius: rootWindow.toolbarPx(7)
                            color: "white"

                            Behavior on x {
                                NumberAnimation { duration: 150 }
                            }
                        }
                    }

                    onCheckedChanged: {
                        generalSettings.lockGridSize = checked;
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: lockGridSwitch.hovered
                    ToolTip.text: qsTr("LNG_00212")
                }

                Rectangle {
                    width: 1
                    height: rootWindow.toolbarPx(20)
                    color: "#2a3540"
                    Layout.alignment: Qt.AlignVCenter
                }

                Repeater {
                    model: [1, 2, 3, 4, 5, 6]
                    delegate: Button {
                        id: gridBtn
                        property int gridSize: modelData
                        text: gridSize + "x" + gridSize
                        enabled: !generalSettings.lockGridSize

                        Layout.preferredWidth: rootWindow.toolbarPx(30)
                        Layout.preferredHeight: rootWindow.toolbarPx(30)

                        // Highlight if this is the current active size!
                        property bool isActive: {
                            return rootWindow.scratchLayout &&
                                   stackLayout.currentIndex === layoutsCollectionModel.count - 1 &&
                                   rootWindow.scratchLayout.size.width === gridSize &&
                                   rootWindow.scratchLayout.size.height === gridSize;
                        }

                        contentItem: Text {
                            text: gridBtn.text
                            font.bold: true
                            font.pixelSize: rootWindow.toolbarPx(10)
                            color: gridBtn.enabled ? (gridBtn.isActive ? "white" : (gridBtn.hovered ? "#ffffff" : "#8898a6")) : "#555555"
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        background: Rectangle {
                            color: gridBtn.isActive ? "#ff7a00" : (gridBtn.pressed ? "#cc121214" : (gridBtn.hovered ? "#3a4550" : "#1c242c"))
                            radius: rootWindow.toolbarPx(15)
                            border.color: gridBtn.isActive ? "#ff9e00" : (gridBtn.hovered ? "#8898a6" : "#2a3540")
                            border.width: 1
                            opacity: gridBtn.enabled ? 1.0 : 0.4
                        }

                        onClicked: {
                            if (generalSettings.lockGridSize) return;
                            rootWindow.showScratchGrid(gridSize, gridSize);
                        }
                    }
                }

                Button {
                    id: moreOptionsButton
                    Layout.preferredWidth: rootWindow.toolbarPx(30)
                    Layout.preferredHeight: rootWindow.toolbarPx(30)
                    Layout.alignment: Qt.AlignVCenter

                    contentItem: Image {
                        anchors.centerIn: parent
                        width: rootWindow.toolbarPx(16)
                        height: rootWindow.toolbarPx(16)
                        sourceSize.width: rootWindow.toolbarPx(16)
                        sourceSize.height: rootWindow.toolbarPx(16)
                        fillMode: Image.PreserveAspectFit
                        source: {
                            var colorStr = moreOptionsButton.hovered ? "white" : "%238898a6";
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><line x1='3' y1='12' x2='21' y2='12'></line><line x1='3' y1='6' x2='21' y2='6'></line><line x1='3' y1='18' x2='21' y2='18'></line></svg>";
                        }
                    }

                    background: Rectangle {
                        color: moreOptionsButton.pressed ? "#cc121214" : (moreOptionsButton.hovered ? "#3a4550" : "#1c242c")
                        radius: rootWindow.toolbarPx(15)
                        border.color: moreOptionsButton.hovered ? "#ff9e00" : "#2a3540"
                        border.width: 1
                    }

                    onClicked: {
                        toolsWindow.visible = !toolsWindow.visible;
                        if (toolsWindow.visible) {
                            toolsWindow.raise();
                            toolsWindow.requestActivate();
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: moreOptionsButton.hovered
                    ToolTip.text: qsTr("LNG_00009")
                }
            }

            Rectangle {
                width: 1
                height: rootWindow.toolbarPx(20)
                color: "#2a3540"
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 6
                Layout.rightMargin: 6
            }

            Flickable {
                id: layoutButtonFlick
                Layout.fillWidth: true
                Layout.preferredHeight: rootWindow.toolbarPx(36)
                contentWidth: layoutButtonRow.implicitWidth
                contentHeight: height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Row {
                    id: layoutButtonRow
                    spacing: rootWindow.toolbarPx(4)
                    height: parent.height

                    Repeater {
                        model: rootWindow.toolbarLayoutModel
                        delegate: Button {
                            id: viewBtn
                            property int layoutIndex: modelData

                            text: {
                                var order = rootWindow.layoutOrderRevision;
                                if (order < 0)
                                    return "";
                                return rootWindow.layoutDisplayName(layoutsCollectionModel, layoutIndex);
                            }

                            height: rootWindow.toolbarPx(30)
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: rootWindow.toolbarPx(12)
                            rightPadding: rootWindow.toolbarPx(12)

                            // Highlight if this is the currently active view!
                            property bool isActive: stackLayout.currentIndex === layoutIndex

                            contentItem: Text {
                                text: viewBtn.text.toUpperCase()
                                font.bold: true
                                font.pixelSize: rootWindow.toolbarPx(10)
                                color: viewBtn.isActive ? "#121214" : (viewBtn.hovered ? "#ffffff" : "#8898a6")
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }

                            background: Rectangle {
                                color: viewBtn.isActive ? "#00f5d4" : (viewBtn.pressed ? "#cc121214" : (viewBtn.hovered ? "#3a4550" : "#1c242c"))
                                radius: rootWindow.toolbarPx(15)
                                border.color: viewBtn.isActive ? "#00f5d4" : (viewBtn.hovered ? "#8898a6" : "#2a3540")
                                border.width: 1
                            }

                            onClicked: {
                                if (rootWindow.scratchLayout && layoutsCollectionModel.get(layoutIndex) === rootWindow.scratchLayout) return;
                                rootWindow.savedLayoutIndex = -1;
                                if (stackLayout.currentIndex === layoutIndex) {
                                    stackLayout.currentIndex = -1;
                                }
                                stackLayout.currentIndex = layoutIndex;
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: {
                        if (layoutButtonFlick.contentWidth <= layoutButtonFlick.width) {
                            wheel.accepted = true;
                            return;
                        }
                        var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x;
                        layoutButtonFlick.contentX = Math.max(0, Math.min(layoutButtonFlick.contentWidth - layoutButtonFlick.width,
                                                                          layoutButtonFlick.contentX - delta));
                        wheel.accepted = true;
                    }
                }
            }
            }
        }
    }

    // Protruding error indicator at the top edge of the window when top bar is hidden
    Rectangle {
        id: topEdgeErrorIndicator
        width: 48
        height: 24
        readonly property bool nvrProblem: NvrStatusManager.monitoringEnabled && NvrStatusManager.hasConfiguredRecorders && NvrStatusManager.hasErrors
        readonly property Item anchorButton: nvrProblem ? nvrStatusButton : bgLogButton
        x: topToolBar.x + 12 + anchorButton.x + anchorButton.width / 2 - width / 2
        anchors.top: parent.top
        color: "transparent"
        z: 100000 // On top of everything

        visible: nvrProblem || HikvisionEventLogger.backgroundProblem
        opacity: (topToolBar.y < -rootWindow.toolbarPx(12)) ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation { duration: 200 }
        }

        Rectangle {
            id: indicatorCircle
            width: 48
            height: 48
            radius: 24
            color: "#dc2626"
            border.color: "#ef4444"
            border.width: 1.5
            anchors.horizontalCenter: parent.horizontalCenter
            y: -28 // Leaves exactly 20px visible inside the screen

            // Dual pulsing glows
            Rectangle {
                id: indicatorGlow1
                width: 48
                height: 48
                radius: 24
                color: "#ef4444"
                anchors.centerIn: parent
                z: -1

                SequentialAnimation on scale {
                    running: topEdgeErrorIndicator.visible && (topToolBar.y < -rootWindow.toolbarPx(12))
                    loops: Animation.Infinite
                    PropertyAnimation { from: 1.0; to: 2.3; duration: 800; easing.type: Easing.OutQuad }
                    PropertyAnimation { from: 2.3; to: 1.0; duration: 800; easing.type: Easing.InQuad }
                }

                SequentialAnimation on opacity {
                    running: topEdgeErrorIndicator.visible && (topToolBar.y < -rootWindow.toolbarPx(12))
                    loops: Animation.Infinite
                    PropertyAnimation { from: 0.85; to: 0.0; duration: 800; easing.type: Easing.OutQuad }
                    PropertyAnimation { from: 0.0; to: 0.85; duration: 800; easing.type: Easing.InQuad }
                }
            }

            Rectangle {
                id: indicatorGlow2
                width: 48
                height: 48
                radius: 24
                color: "#ef4444"
                anchors.centerIn: parent
                z: -2

                SequentialAnimation on scale {
                    running: topEdgeErrorIndicator.visible && (topToolBar.y < -rootWindow.toolbarPx(12))
                    loops: Animation.Infinite
                    PropertyAnimation { from: 1.0; to: 1.6; duration: 600; easing.type: Easing.OutQuad }
                    PropertyAnimation { from: 1.6; to: 1.0; duration: 600; easing.type: Easing.InQuad }
                }

                SequentialAnimation on opacity {
                    running: topEdgeErrorIndicator.visible && (topToolBar.y < -rootWindow.toolbarPx(12))
                    loops: Animation.Infinite
                    PropertyAnimation { from: 0.6; to: 0.1; duration: 600; easing.type: Easing.OutQuad }
                    PropertyAnimation { from: 0.1; to: 0.6; duration: 600; easing.type: Easing.InQuad }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                text: "!"
                color: "white"
                font.bold: true
                font.pixelSize: 13
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (topEdgeErrorIndicator.nvrProblem)
                        nvrStatusDialog.open();
                    else
                        bgLogMenu.popup(topEdgeErrorIndicator, 0, topEdgeErrorIndicator.height);
                }

                ToolTip.delay: Compact.toolTipDelay
                ToolTip.timeout: Compact.toolTipTimeout
                ToolTip.visible: containsMouse
                ToolTip.text: topEdgeErrorIndicator.nvrProblem ? qsTr("LNG_00211") : HikvisionEventLogger.backgroundText
            }
        }
    }

    Item {
        anchors.fill: parent

        // Placeholder when no view is selected in auxiliary window
        Rectangle {
            anchors.fill: parent
            color: "#0f151b"
            visible: Context.isAuxiliary && stackLayout.currentIndex === -1

            // Seledynowa ramka wewnątrz pustego pola (matching the archive viewport placeholder style)
            Rectangle {
                anchors.fill: parent
                anchors.margins: 16
                color: "transparent"
                border.color: "#00f5d4"
                border.width: 1.5
                radius: 8
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12

                Image {
                    Layout.preferredWidth: 64
                    Layout.preferredHeight: 64
                    Layout.alignment: Qt.AlignHCenter
                    sourceSize: Qt.size(64, 64)
                    fillMode: Image.PreserveAspectFit
                    source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='3' width='20' height='14' rx='2' ry='2'></rect><line x1='8' y1='21' x2='16' y2='21'></line><line x1='12' y1='17' x2='12' y2='21'></line></svg>"
                }

                Text {
                    text: qsTr("LNG_00017")
                    color: "#00f5d4"
                    font.bold: true
                    font.pixelSize: 18
                    Layout.alignment: Qt.AlignHCenter
                }

                Text {
                    text: qsTr("LNG_00016")
                    color: "#8898a6"
                    font.pixelSize: 12
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }

        StackLayout {
            id: stackLayout

            visible: false
            currentIndex: -1
            anchors.fill: parent

            onCurrentIndexChanged: {
                if (rootWindow.layoutReorderHold)
                    return;
                windowLayoutSettings.currentIndex = currentIndex;
            }

            Repeater {
                id: layoutRepeater
                model: layoutsCollectionModel

                ViewportsLayout {
                    model: layoutModel
                    focus: true
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            z: 1
            onWheel: {
                var layout = layoutRepeater.itemAt(stackLayout.currentIndex);
                if (wheel.modifiers & Qt.ControlModifier) {
                    if (layout) {
                        var zp = mapToItem(layout, wheel.x, wheel.y);
                        if (layout.digitalZoomAt(zp.x, zp.y, rootWindow.wheelDeltaY(wheel))) {
                            wheel.accepted = true;
                            return;
                        }
                    }
                    wheel.accepted = false;
                    return;
                }
                if (topToolBarMouseArea.containsMouse) {
                    wheel.accepted = true;
                    return;
                }
                if (layout) {
                    var lp = mapToItem(layout, wheel.x, wheel.y);
                    if (layout.boxZoomWheelAt(lp.x, lp.y, wheel.angleDelta.y, wheel.modifiers)) {
                        wheel.accepted = true;
                        return;
                    }
                }
                if (layout && layout.fullScreenIndex >= 0) {
                    var delta = rootWindow.wheelDeltaY(wheel);
                    if (delta !== 0 && rootWindow.wheelStepAllowed())
                        layout.stepMaximizedCamera(delta > 0 ? 1 : -1);
                    wheel.accepted = true;
                    return;
                }
                if (layout && layout.size && layout.size.width === 1 && layout.size.height === 1) {
                    return;
                }
                rootWindow.handleLayoutWheel(wheel, layoutsCollectionModel, stackLayout.currentIndex, function(idx) {
                    stackLayout.currentIndex = idx;
                });
            }
        }
    }

    // Separate utility Window for options (SideBar contents)
    Window {
        id: sidebarWindow
        title: qsTr("LNG_00210")
        width: Math.round(rootWindow.width * 0.85)
        height: Math.round(rootWindow.height * 0.85)
        visible: false
        color: "#0f151b"

        onVisibleChanged: {
            if (sideBarLoader.item) {
                try {
                    sideBarLoader.item.resetPathChangesCheckbox();
                } catch(e) {}
            }
            if (visible) {
                if (sideBarLoader.source == "" && !Context.config.kioskMode) {
                    sideBarLoader.source = "SideBar.qml";
                }
                var defaultWidth = Math.round(rootWindow.width * 0.85);
                var defaultHeight = Math.round(rootWindow.height * 0.85);
                if (sidebarWindow.width === 320 || sidebarWindow.width <= 0) {
                    sidebarWindow.width = defaultWidth;
                }
                if (sidebarWindow.height === 750 || sidebarWindow.height <= 0) {
                    sidebarWindow.height = defaultHeight;
                }
                sidebarWindow.x = Math.round(rootWindow.x + (rootWindow.width - sidebarWindow.width) / 2);
                sidebarWindow.y = Math.round(rootWindow.y + (rootWindow.height - sidebarWindow.height) / 2);
            }
        }

        Settings {
            id: sidebarWindowSettings
            fileName: Context.config.fileName
            category: "SidebarWindow"
            property int x: -1
            property int y: -1
            property int width: -1
            property int height: -1
            property bool visible: false
        }

        Component.onCompleted: {
            var defaultWidth = Math.round(rootWindow.width * 0.85);
            var defaultHeight = Math.round(rootWindow.height * 0.85);
            var defaultX = Math.round(rootWindow.x + (rootWindow.width - defaultWidth) / 2);
            var defaultY = Math.round(rootWindow.y + (rootWindow.height - defaultHeight) / 2);

            sidebarWindow.width = (sidebarWindowSettings.width > 0 && sidebarWindowSettings.width !== 320) ? sidebarWindowSettings.width : defaultWidth;
            sidebarWindow.height = (sidebarWindowSettings.height > 0 && sidebarWindowSettings.height !== 750) ? sidebarWindowSettings.height : defaultHeight;
            sidebarWindow.x = (sidebarWindowSettings.x >= 0 && sidebarWindowSettings.x !== 100) ? sidebarWindowSettings.x : defaultX;
            sidebarWindow.y = (sidebarWindowSettings.y >= 0 && sidebarWindowSettings.y !== 100) ? sidebarWindowSettings.y : defaultY;

            if (Context.isAuxiliary) {
                sidebarWindow.visible = false;
            } else {
                sidebarWindow.visible = sidebarWindowSettings.visible;

                sidebarWindow.xChanged.connect(saveGeometry);
                sidebarWindow.yChanged.connect(saveGeometry);
                sidebarWindow.widthChanged.connect(saveGeometry);
                sidebarWindow.heightChanged.connect(saveGeometry);
                sidebarWindow.visibleChanged.connect(saveGeometry);
            }
        }



        function saveGeometry() {
            sidebarWindowSettings.x = sidebarWindow.x;
            sidebarWindowSettings.y = sidebarWindow.y;
            sidebarWindowSettings.width = sidebarWindow.width;
            sidebarWindowSettings.height = sidebarWindow.height;
            sidebarWindowSettings.visible = sidebarWindow.visible;
        }

        Loader {
            id: sideBarLoader
            anchors.fill: parent
        }
    }

    Connections {
        target: SingleApplication
        function onMessageReceived(message) {
            if (message === "openNewWindow") {
                rootWindow.openAuxiliaryWindow();
            }
        }
    }

    // Keeps the background service in step with the saved setting (it also repairs a moved program path).
    Timer {
        id: backgroundServiceTimer
        interval: 8000
        repeat: false
        onTriggered: if (generalSettings.logDetectionEvents) HikvisionEventLogger.ensureBackground(Context.config.fileName)
    }

    // The list of recorder cameras that show a detection frame has been seen to come back empty after a start. This prints how
    // many it holds whenever it loads or changes, and a warning when a list that had cameras becomes empty, so the terminal
    // shows when and what happened.
    // The setting starts as []. It is not written until this window has read the saved list, so a start cannot save that
    // empty starting value over the real one. After the read, an empty list is a real choice and is saved.
    property bool nvrListReady: false
    function setTargetNvrOnCameras(value) {
        if (!nvrListReady)
            return;
        generalSettings.targetNvrOnCameras = value;
    }
    property int nvrListCount: -1
    function noteNvrList() {
        var n = 0;
        try { n = JSON.parse(generalSettings.targetNvrOnCameras || "[]").length; } catch (e) { n = -2; }
        if (n === 0 && rootWindow.nvrListCount > 0)
            console.warn("[Settings] the list of recorder cameras with a detection frame was emptied (it had", rootWindow.nvrListCount, "cameras)");
        else if (n !== rootWindow.nvrListCount)
            console.log("[Settings] recorder cameras with a detection frame:", n);
        rootWindow.nvrListCount = n;
    }

    function flushSettingsToDisk() {
        if (saveTimer.running) {
            saveTimer.stop();
        }
        var modelsJson = rootWindow.persistedLayoutsJson();
        rootWindow.lastSavedModelsJson = modelsJson;
        layoutsCollectionSettings.models = modelsJson;

        Context.writeSetting("", "singleApplication", generalSettings.singleApplication);
        Context.writeSetting("", "allowSwappingViewports", generalSettings.allowSwappingViewports);
        Context.writeSetting("", "enableContextMenu", generalSettings.enableContextMenu);
        Context.writeSetting("", "enableRemoveCamera", generalSettings.enableRemoveCamera);
        Context.writeSetting("", "enableChangeViewportSettings", generalSettings.enableChangeViewportSettings);
        Context.writeSetting("", "enableStreamSelection", generalSettings.enableStreamSelection);
        Context.writeSetting("", "lockGridSize", generalSettings.lockGridSize);
        Context.writeSetting("", "snapshotPath", generalSettings.snapshotPath);
        Context.writeSetting("", "videoPath", generalSettings.videoPath);
        Context.writeSetting("", "disableAudio", generalSettings.disableAudio);
        Context.writeSetting("", "webBrowserChoice", generalSettings.webBrowserChoice);
        Context.writeSetting("", "disableTalk", generalSettings.disableTalk);
        Context.writeSetting("", "showTargetIndicator", generalSettings.showTargetIndicator);
        Context.writeSetting("", "targetHoldSeconds", generalSettings.targetHoldSeconds);
        Context.writeSetting("", "picturesPerCamera", generalSettings.picturesPerCamera);
        Context.writeSetting("", "targetSource", generalSettings.targetSource);
        Context.writeSetting("", "targetSourceOverrides", generalSettings.targetSourceOverrides);
        Context.writeSetting("", "targetKinds", generalSettings.targetKinds);
        Context.writeSetting("", "overlayText", generalSettings.overlayText);
        Context.writeSetting("", "logDetectionEvents", generalSettings.logDetectionEvents);
        Context.writeSetting("", "checkSetupAtStart", generalSettings.checkSetupAtStart);
        Context.writeSetting("", "targetTargets", generalSettings.targetTargets);
        Context.writeSetting("", "logUnlabelledMotion", generalSettings.logUnlabelledMotion);
        Context.writeSetting("", "frameUnlabelledMotion", generalSettings.frameUnlabelledMotion);
        Context.writeSetting("", "targetOffCameras", generalSettings.targetOffCameras);
        if (rootWindow.nvrListReady)
            Context.writeSetting("", "targetNvrOnCameras", generalSettings.targetNvrOnCameras);
        Context.writeSetting("", "talkMicrophone", generalSettings.talkMicrophone);
        Context.writeSetting("", "talkGain", generalSettings.talkGain);
        Context.writeSetting("", "talkBoostDb", generalSettings.talkBoostDb);
        Context.writeSetting("", "auxiliaryLimit", generalSettings.auxiliaryLimit);
        Context.writeSetting("", "auxiliaryScale", generalSettings.auxiliaryScale);
        Context.writeSetting("", "playbackOffsetSeconds", generalSettings.playbackOffsetSeconds);
        Context.writeSetting("", "playbackTimelineHours", generalSettings.playbackTimelineHours);
        Context.writeSetting("", "pauseLiveDuringPlayback", generalSettings.pauseLiveDuringPlayback);
        Context.writeSetting("", "enableDiagnosticLogs", generalSettings.enableDiagnosticLogs);
        Context.writeSetting("", "language", Context.getLanguage());

        Context.writeSetting("Hikvision", "recordersJson", hikvisionSettings.recordersJson);

        Context.writeSetting("ViewportsLayoutsCollection", "models", modelsJson);
        Context.writeSetting("ViewportsLayoutsCollection", "defaultAVFormatOptions", layoutsCollectionSettings.defaultAVFormatOptions);

        Context.writeSetting("View", "hideCursorWhenFullScreen", viewSettings.hideCursorWhenFullScreen);
        Context.writeSetting("View", "hideCursorWhenWindowed", viewSettings.hideCursorWhenWindowed);
        Context.writeSetting("View", "showChannelStatus", viewSettings.showChannelStatus);
        Context.writeSetting("View", "showChannelResolution", viewSettings.showChannelResolution);
        Context.writeSetting("View", "hideInfoBadgesWhenIdle", viewSettings.hideInfoBadgesWhenIdle);
        Context.writeSetting("View", "showCameraInfo", viewSettings.showCameraInfo);
        Context.writeSetting("View", "hoverControlIcons", viewSettings.hoverControlIcons);
        Context.writeSetting("View", "showInfoOnHoverOnly", viewSettings.showInfoOnHoverOnly);
        Context.writeSetting("View", "showTopBarByDefault", viewSettings.showTopBarByDefault);
        Context.writeSetting("View", "disableViewportZoomAnimation", viewSettings.disableViewportZoomAnimation);

        Context.writeSetting("Viewport", "noUnmuteWhenFullScreen", viewportSettings.noUnmuteWhenFullScreen);

        if (!Context.isAuxiliary) {
            Context.writeSetting("MainLayout", "currentIndex", stackLayout.currentIndex);
            Context.writeSetting("RootWindow", "width", rootWindow.width);
            Context.writeSetting("RootWindow", "height", rootWindow.height);
            Context.writeSetting("RootWindow", "fullScreen", Context.config.fullScreen);
        }
    }

    // Which cameras the check covers: every Hikvision camera that is switched on for detection. A camera behind
    // a recorder with more than two cameras is read through the recorder; a camera or dual-lens camera has its
    // own address. With onlyKey (recorderIp#channel) only that camera is asked.
    function checkDetectionSetup(onlyKey) {
        var list = [];
        try {
            list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]");
        } catch (e) {
            return 0;
        }
        var nvrOn = [];
        var camOff = [];
        try { nvrOn = JSON.parse(generalSettings.targetNvrOnCameras || "[]"); } catch (e1) {}
        try { camOff = JSON.parse(generalSettings.targetOffCameras || "[]"); } catch (e2) {}
        var through = generalSettings.targetSource === "recorder";
        var asked = 0;
        for (var i = 0; i < list.length; ++i) {
            var rec = list[i];
            var ip = (rec.ip || "").trim().split(":")[0];
            if (!rec.username || !rec.password || ip === "")
                continue;
            var cams = rec.cameras || [];
            var behind = cams.length > 2;
            for (var j = 0; j < cams.length; ++j) {
                var ch = parseInt(cams[j].channelId);
                var key = ip + "#" + ch;
                if (onlyKey !== undefined && onlyKey !== "" && onlyKey !== key)
                    continue;
                if (onlyKey === undefined || onlyKey === "") {
                    // Everything: only cameras that are switched on for detection.
                    if (behind ? nvrOn.indexOf(key) < 0 : camOff.indexOf(ip) >= 0)
                        continue;
                }
                var nm = (rec.name || ip) + " Ch. " + ch + " " + (cams[j].customName || cams[j].name || ("Camera " + ch));
                HikvisionSetupCheck.check(key, nm, ip, parseInt(rec.httpPort) || 80, rec.username, rec.password, ch,
                                          behind, through, Context.configDirPath());
                ++asked;
            }
        }
        return asked;
    }

    Timer {
        id: startupSetupCheckTimer
        interval: 20000 // let the wall and its streams settle first
        repeat: false
        onTriggered: rootWindow.checkDetectionSetup("")
    }

    // The detection filters live in the listener, so it is told whenever the settings change.
    function applyDetectionFilters() {
        HikvisionEvents.setAllowedKinds(generalSettings.targetKinds);
        HikvisionEvents.setAllowedTargets(generalSettings.targetTargets);
        HikvisionEvents.setMaxPictures(generalSettings.picturesPerCamera);
        HikvisionEvents.setUnlabelledMotion(generalSettings.logUnlabelledMotion, generalSettings.frameUnlabelledMotion);
    }

    // The logger keeps one watcher on every camera while the log switch is on, independent of the tiles.
    function applyEventLogger() {
        if (Context.isAuxiliary)
            return;
        // While this window is open it always logs every configured camera. The setting only decides whether the
        // background service takes over after the window is closed.
        HikvisionEventLogger.configure(true, NvrStatusManager.withoutOfflineRecorders(rootWindow.hikvisionRecordersJson || "[]"),
                                       generalSettings.targetSource, Context.configDirPath(), generalSettings.targetSourceOverrides);
        HikvisionEventLogger.monitorBackground(generalSettings.logDetectionEvents, Context.configDirPath(), Context.config.fileName);
    }

    Connections {
        target: generalSettings
        onLogDetectionEventsChanged: rootWindow.applyEventLogger()
        onTargetSourceChanged: rootWindow.applyEventLogger()
        onTargetKindsChanged: rootWindow.applyDetectionFilters()
        onTargetTargetsChanged: rootWindow.applyDetectionFilters()
        onPicturesPerCameraChanged: rootWindow.applyDetectionFilters()
    }

    Component.onCompleted: {
        stackLayout.visible = true;
        rootWindow.applyDetectionFilters();
        rootWindow.applyEventLogger();
        WebBrowser.setChoice(generalSettings.webBrowserChoice);
        rootWindow.noteNvrList();
        if (!Context.isAuxiliary && generalSettings.logDetectionEvents)
            backgroundServiceTimer.start();
        if (!Context.isAuxiliary) {
            var overlaySaved = OverlayText.recoverEmptyList(Context.config.fileName, generalSettings.overlayText || "{}");
            if (overlaySaved !== (generalSettings.overlayText || "{}"))
                generalSettings.overlayText = overlaySaved;
            OverlayText.apply(generalSettings.overlayText || "{}");
        }
        if (generalSettings.checkSetupAtStart && !Context.isAuxiliary)
            startupSetupCheckTimer.start();

        var snapPath = Context.sanitizePlatformPath(generalSettings.snapshotPath, Context.defaultPicturesPath());
        if (generalSettings.snapshotPath !== snapPath) {
            generalSettings.snapshotPath = snapPath;
        }
        Context.mkpath(snapPath);

        var vidPath = Context.sanitizePlatformPath(generalSettings.videoPath, Context.defaultMoviesPath());
        if (generalSettings.videoPath !== vidPath) {
            generalSettings.videoPath = vidPath;
        }
        Context.mkpath(vidPath);

        if (Context.isFirstRun && !Context.isAuxiliary) {
            firstRunHelpTimer.start();
        }

        contentItem.wheel.connect(function(wheel) {
            if (!(wheel.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                var layout = layoutRepeater.itemAt(stackLayout.currentIndex);
                if (layout && layout.fullScreenIndex >= 0) {
                    var delta = wheelDeltaY(wheel);
                    if (delta !== 0 && wheelStepAllowed())
                        layout.stepMaximizedCamera(delta > 0 ? 1 : -1);
                    wheel.accepted = true;
                    return;
                }
            }
            handleLayoutWheel(wheel, layoutsCollectionModel, stackLayout.currentIndex, function(idx) {
                stackLayout.currentIndex = idx;
            });
        });
    }


    InstructionsWindow {
        id: instructionsWindow
        visible: false
    }

    Timer {
        id: firstRunHelpTimer
        interval: 350
        repeat: false
        onTriggered: {
            instructionsWindow.show();
            instructionsWindow.raise();
            instructionsWindow.requestActivate();
        }
    }

    ConfirmDialog {
        id: quitConfirmDialog
        title: Context.isAuxiliary ? qsTr("LNG_00121") : qsTr("LNG_00007")
        message: Context.isAuxiliary ? qsTr("LNG_00209") : qsTr("LNG_00006")
        confirmButtonText: qsTr("LNG_00005")
        cancelButtonText: qsTr("LNG_00004")
        isDanger: true
        onAccepted: {
            if (saveTimer.running) {
                saveTimer.stop();
                if (!rootWindow.isSyncing) {
                    var json = rootWindow.persistedLayoutsJson();
                    rootWindow.lastSavedModelsJson = json;
                    layoutsCollectionSettings.models = json;
                    console.log("[Sync] Emergency immediate layouts save completed on close.");
                }
            }
            rootWindow.closeAccepted = true;
            rootWindow.hide();
            Qt.quit();
        }
    }

    function droppedAudioCameraLabel() {
        var host = RtspAudioCompat.droppedHost || "";
        var channel = RtspAudioCompat.droppedChannel || 0;
        if (host.length === 0)
            return "";
        var list = [];
        try { list = JSON.parse(rootWindow.hikvisionRecordersJson || "[]"); } catch (e) {}
        var rec = null;
        for (var i = 0; i < list.length; ++i) {
            if (String(list[i].ip || "").split(":")[0] === host) {
                rec = list[i];
                break;
            }
        }
        var place = channel > 0 ? (host + ", channel " + channel) : host;
        if (!rec)
            return place;
        var recName = String(rec.name || "").trim();
        var cams = rec.cameras || [];
        if (cams.length <= 1)
            return recName.length > 0 ? (recName + " (" + host + ")") : place;
        var camName = "";
        for (var c = 0; c < cams.length; ++c) {
            if (parseInt(cams[c].channelId) === channel) {
                camName = String(cams[c].customName || cams[c].name || "").trim();
                break;
            }
        }
        var head = camName.length > 0 ? camName : (recName.length > 0 ? recName : host);
        return channel > 0 ? (head + " (" + host + ", channel " + channel + ")") : (head + " (" + host + ")");
    }

    function droppedAudioMessage() {
        var who = rootWindow.droppedAudioCameraLabel();
        var tail = " Choose the cameras that should have sound and are silent. Only those cameras are repaired on this computer. Every other camera stays as it is. The same list is under Settings, Audio.";
        if (who.length > 0)
            return "Live audio from " + who + " was dropped. That camera described its audio in a way the player cannot use." + tail;
        return "A recorder described its live audio in a way the player cannot use, so the sound was dropped." + tail;
    }

    Connections {
        target: RtspAudioCompat
        onOfferPendingChanged: {
            if (RtspAudioCompat.offerPending && !aacRepairDialog.visible) {
                aacRepairDialog.message = rootWindow.droppedAudioMessage();
                aacRepairDialog.open();
            }
        }
    }

    function openAacRepairWindow() {
        var w = aacRepairComponent.createObject(rootWindow);
        if (w)
            w.show();
    }

    Component {
        id: aacRepairComponent
        AacRepairWindow {}
    }

    ConfirmDialog {
        id: aacRepairDialog
        title: qsTr("Live audio was dropped")
        width: 520
        message: rootWindow.droppedAudioMessage()
        confirmButtonText: qsTr("Choose cameras")
        cancelButtonText: qsTr("Not now")
        isDanger: false
        onAccepted: {
            RtspAudioCompat.dismissOffer();
            rootWindow.openAacRepairWindow();
        }
        onRejected: RtspAudioCompat.dismissOffer()
        Component.onCompleted: {
            if (RtspAudioCompat.offerPending) {
                message = rootWindow.droppedAudioMessage();
                open();
            }
        }
    }

    NvrStatusDialog {
        id: nvrStatusDialog
    }

    ToolsWindow {
        id: toolsWindow
        visible: false
    }

    // Premium semi-transparent draggable panel for system stats
    Rectangle {
        id: statsPanel
        width: 400
        height: 350
        x: 20
        y: 60
        color: "#59121214" // 35% opacity dark background for better readability
        border.color: "#00ff66"
        border.width: 1
        radius: 8
        z: 99999
        visible: systemStatsSwitch.checked

        property int minWidth: 250
        property int minHeight: 220

        property var cpuHistory: []
        property var gpuHistory: []
        property var netHistory: []
        property var tempCpuHistory: []
        property var tempGpuHistory: []
        property var tempDiskHistory: []

        readonly property string cpuColor: "#3ddc97"
        readonly property string gpuColor: "#4c9aff"
        readonly property string netColor: "#f0b429"
        readonly property string tempCpuColor: "#ff6b4a"
        readonly property string tempGpuColor: "#c084fc"
        readonly property string tempDiskColor: "#3ec6ff"

        function chartY(value, lo, hi, h) {
            var span = hi - lo;
            if (span < 0.001)
                span = 1;
            var t = (value - lo) / span;
            if (t < 0)
                t = 0;
            if (t > 1)
                t = 1;
            return h - t * h;
        }

        function paintGrid(ctx, w, h) {
            ctx.clearRect(0, 0, w, h);
            ctx.strokeStyle = "rgba(176, 196, 210, 0.5)";
            ctx.lineWidth = 0.8;
            ctx.strokeRect(0, 0, w, h);
            ctx.beginPath();
            ctx.strokeStyle = "rgba(176, 196, 210, 0.16)";
            var hStep = h / 4;
            for (var y = hStep; y < h; y += hStep) {
                ctx.moveTo(0, y);
                ctx.lineTo(w, y);
            }
            var colWidth = w / 6;
            for (var col = 1; col < 6; ++col) {
                var xv = col * colWidth;
                ctx.moveTo(xv, 0);
                ctx.lineTo(xv, h);
            }
            ctx.stroke();
        }

        // values below 0 are gaps (a temperature sensor was missing that second).
        function paintSeries(ctx, w, h, values, lo, hi, color, doFill) {
            if (!values || values.length < 2 || w < 2 || h < 2)
                return;
            var step = w / (360 - 1);
            var startX = w - (values.length - 1) * step;
            var usable = false;
            for (var n = 0; n < values.length; n++) {
                if (values[n] >= 0) {
                    usable = true;
                    break;
                }
            }
            if (!usable)
                return;

            if (doFill) {
                ctx.beginPath();
                ctx.moveTo(startX, h);
                for (var i = 0; i < values.length; i++) {
                    var sample = values[i] < 0 ? lo : values[i];
                    var yv = statsPanel.chartY(sample, lo, hi, h);
                    ctx.lineTo(startX + i * step, Math.max(1, Math.min(h - 1, yv)));
                }
                ctx.lineTo(startX + (values.length - 1) * step, h);
                ctx.closePath();
                ctx.globalAlpha = 0.2;
                ctx.fillStyle = color;
                ctx.fill();
                ctx.globalAlpha = 1;
            }

            ctx.beginPath();
            ctx.strokeStyle = color;
            ctx.lineWidth = 1.6;
            ctx.lineJoin = "round";
            ctx.lineCap = "round";
            var drawing = false;
            for (var j = 0; j < values.length; j++) {
                if (values[j] < 0) {
                    drawing = false;
                    continue;
                }
                var x = startX + j * step;
                var yLine = statsPanel.chartY(values[j], lo, hi, h);
                yLine = Math.max(1, Math.min(h - 1, yLine));
                if (!drawing) {
                    ctx.moveTo(x, yLine);
                    drawing = true;
                } else {
                    ctx.lineTo(x, yLine);
                }
            }
            ctx.stroke();
        }

        function netScaleHi() {
            var maxVal = 4;
            var hist = statsPanel.netHistory;
            if (!hist)
                return maxVal;
            for (var i = 0; i < hist.length; i++) {
                if (hist[i] > maxVal)
                    maxVal = hist[i];
            }
            return maxVal;
        }

        function fahrenheit() {
            return generalSettings.statsTemperatureUnit === "F";
        }

        // History stays in Celsius. The panel converts when it draws.
        function displayTemp(celsius) {
            if (celsius < 0)
                return celsius;
            return statsPanel.fahrenheit() ? (celsius * 9 / 5 + 32) : celsius;
        }

        function displaySeries(values) {
            if (!values || !statsPanel.fahrenheit())
                return values;
            var out = [];
            for (var i = 0; i < values.length; i++)
                out.push(values[i] < 0 ? -1 : values[i] * 9 / 5 + 32);
            return out;
        }

        function formatTemp(celsius, unit) {
            if (celsius < 0)
                return "";
            if (unit === "F")
                return (celsius * 9 / 5 + 32).toFixed(0) + "\u00B0F";
            return celsius.toFixed(0) + "\u00B0C";
        }

        // 30°C (86°F) at the bottom, at least 105°C (221°F) at the top, so a hot
        // package sits near the top and a cool drive stays low. The scale grows
        // past that if a sample would be clipped.
        function tempScaleLo() {
            return statsPanel.fahrenheit() ? 86 : 30;
        }

        function tempScaleHi() {
            var hi = statsPanel.fahrenheit() ? 221 : 105;
            var series = [statsPanel.tempCpuHistory, statsPanel.tempGpuHistory, statsPanel.tempDiskHistory];
            for (var s = 0; s < series.length; s++) {
                var hist = series[s];
                if (!hist)
                    continue;
                for (var i = 0; i < hist.length; i++) {
                    if (hist[i] < 0)
                        continue;
                    var shown = statsPanel.displayTemp(hist[i]);
                    if (shown > hi)
                        hi = shown;
                }
            }
            return hi;
        }

        function paintTempGuide(ctx, w, h) {
            var lo = statsPanel.tempScaleLo();
            var hi = statsPanel.tempScaleHi();
            if (hi <= lo)
                return;
            // The same place on the scale either way: 90°C, which is 194°F.
            var guide = statsPanel.fahrenheit() ? 194 : 90;
            var y = statsPanel.chartY(guide, lo, hi, h);
            ctx.beginPath();
            ctx.strokeStyle = "rgba(255, 107, 74, 0.35)";
            ctx.lineWidth = 1;
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
            ctx.stroke();
            ctx.fillStyle = "rgba(255, 107, 74, 0.75)";
            ctx.font = "10px sans-serif";
            ctx.fillText(statsPanel.fahrenheit() ? "194\u00B0" : "90\u00B0", 4, Math.max(10, y - 3));
        }

        function pushSample(series, value) {
            var next = series.slice();
            next.push(value);
            if (next.length > 360)
                next.shift();
            return next;
        }

        // Fills the charts from the history SystemStats collected while the
        // panel was closed, so it opens with the whole window instead of from
        // zero. Longer windows are averaged down to the charts' 360 slots.
        function seedHistory() {
            statsPanel.cpuHistory = SystemStats.historySnapshot("cpu", 360);
            statsPanel.gpuHistory = SystemStats.historySnapshot("gpu", 360);
            statsPanel.netHistory = SystemStats.historySnapshot("net", 360);
            statsPanel.tempCpuHistory = SystemStats.historySnapshot("tempCpu", 360);
            statsPanel.tempGpuHistory = SystemStats.historySnapshot("tempGpu", 360);
            statsPanel.tempDiskHistory = SystemStats.historySnapshot("tempDisk", 360);
            usageCanvas.requestPaint();
            netCanvas.requestPaint();
            tempCanvas.requestPaint();
        }

        // The rolling buffer lives in SystemStats, so the QML arrays can be
        // dropped while the panel is closed; they are reseeded when it opens.
        function clearHistory() {
            statsPanel.cpuHistory = [];
            statsPanel.gpuHistory = [];
            statsPanel.netHistory = [];
            statsPanel.tempCpuHistory = [];
            statsPanel.tempGpuHistory = [];
            statsPanel.tempDiskHistory = [];
        }

        Component.onCompleted: {
            SystemStats.active = visible;
            if (visible)
                seedHistory();
        }

        onVisibleChanged: {
            SystemStats.active = visible;
            if (visible) {
                seedHistory();
            } else {
                clearHistory();
                gc(); // Optionally trigger garbage collection to free memory immediately
            }
        }

        Connections {
            target: SystemStats
            function onStatsChanged() {
                if (!statsPanel.visible)
                    return; // the history is kept in SystemStats while the panel is closed

                statsPanel.cpuHistory = statsPanel.pushSample(statsPanel.cpuHistory, SystemStats.cpuUsage);
                statsPanel.gpuHistory = statsPanel.pushSample(statsPanel.gpuHistory, SystemStats.gpuUsage);
                statsPanel.netHistory = statsPanel.pushSample(statsPanel.netHistory, SystemStats.netUsage);
                statsPanel.tempCpuHistory = statsPanel.pushSample(statsPanel.tempCpuHistory, SystemStats.cpuTemperature);
                statsPanel.tempGpuHistory = statsPanel.pushSample(statsPanel.tempGpuHistory, SystemStats.gpuTemperature);
                statsPanel.tempDiskHistory = statsPanel.pushSample(statsPanel.tempDiskHistory, SystemStats.diskTemperature);

                usageCanvas.requestPaint();
                netCanvas.requestPaint();
                tempCanvas.requestPaint();
            }

            // A new window length (chosen with the small button in the title
            // bar) redraws the charts from the buffer right away.
            function onHistoryMinutesChanged() {
                if (statsPanel.visible)
                    statsPanel.seedHistory();
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                
                Text {
                    text: qsTr("LNG_00208")
                    color: "#00ff66"
                    font.bold: true
                    font.pixelSize: 13
                    Layout.fillWidth: true
                }

                // History window: click to step through 5, 15, 30 and 60
                // minutes. Saved with the settings; the charts redraw from
                // the buffer the moment it changes.
                Rectangle {
                    id: historyLengthButton
                    width: historyLengthText.implicitWidth + 16
                    height: 22
                    radius: 4
                    color: historyLengthArea.pressed ? "#2a3a4a" : (historyLengthArea.containsMouse ? "#22303d" : "#1a242d")
                    border.width: 1
                    border.color: historyLengthArea.containsMouse ? "#00ff66" : "#2a3540"

                    Text {
                        id: historyLengthText
                        anchors.centerIn: parent
                        text: SystemStats.historyMinutes + " min"
                        color: "#c8d2da"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        id: historyLengthArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var options = [5, 15, 30, 60];
                            var cur = SystemStats.historyMinutes;
                            var next = options[0];
                            for (var i = 0; i < options.length; ++i) {
                                if (cur >= options[i])
                                    next = options[(i + 1) % options.length];
                            }
                            generalSettings.statsHistoryMinutes = next;
                        }
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: containsMouse
                        ToolTip.text: qsTr("History length: how long the charts remember, even while the panel is closed. Click to switch between 5, 15, 30 and 60 minutes.")
                    }
                }

                Image {
                    id: dragHandle
                    width: 24
                    height: 24
                    sourceSize.width: 24
                    sourceSize.height: 24
                    fillMode: Image.PreserveAspectFit
                    source: {
                        var colorStr = dragArea.pressed ? "%23ffffff" : (dragArea.containsMouse ? "%2300ffd8" : "%2300ff66");
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><circle cx='9' cy='5' r='1.5'></circle><circle cx='9' cy='12' r='1.5'></circle><circle cx='9' cy='19' r='1.5'></circle><circle cx='15' cy='5' r='1.5'></circle><circle cx='15' cy='12' r='1.5'></circle><circle cx='15' cy='19' r='1.5'></circle></svg>";
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.SizeAllCursor

                        property point clickPos: "0,0"
                        onPressed: {
                            clickPos = Qt.point(mouse.x, mouse.y)
                        }
                        onPositionChanged: {
                            if (pressed) {
                                var delta = Qt.point(mouse.x - clickPos.x, mouse.y - clickPos.y)
                                statsPanel.x = Math.max(0, Math.min(rootWindow.width - statsPanel.width, statsPanel.x + delta.x))
                                statsPanel.y = Math.max(50, Math.min(rootWindow.height - statsPanel.height, statsPanel.y + delta.y))
                            }
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: dragArea.containsMouse
                    ToolTip.text: qsTr("LNG_00207")
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 20

                Text {
                    text: qsTr("LNG_00206") + SystemStats.ramUsage.toFixed(1) + " MB"
                    color: "#c8d2da"
                    font.pixelSize: 11
                    font.bold: true
                }

                Text {
                    text: qsTr("LNG_00205") + SystemStats.vramUsage.toFixed(1) + " MB"
                    color: "#c8d2da"
                    font.pixelSize: 11
                    font.bold: true
                }
            }

            Text {
                text: SystemStats.rtspStreams + (SystemStats.rtspStreams === 1 ? qsTr(" live stream (FFmpeg)") : qsTr(" live streams (FFmpeg)"))
                      + " · " + SystemStats.sdkStreams + (SystemStats.sdkStreams === 1 ? qsTr(" playback (SDK)") : qsTr(" playbacks (SDK)"))
                color: "#8898a6"
                font.pixelSize: 11
            }

            Text {
                // Frames thrown away because a decoder's queue was full, and demux or
                // decode hiccups, added up since KVision started.
                text: qsTr("Decode since start: %1 frames dropped · %2 errors")
                    .arg(SystemStats.decDropsTotal).arg(SystemStats.decErrorsTotal)
                color: (SystemStats.decDropsTotal > 0 || SystemStats.decErrorsTotal > 0) ? "#e0a040" : "#8898a6"
                font.pixelSize: 11
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: qsTr("LNG_00204") + SystemStats.cpuUsage.toFixed(1) + "%"
                    color: statsPanel.cpuColor
                    font.pixelSize: 11
                    font.bold: true
                }
                Text {
                    text: qsTr("LNG_00203") + SystemStats.gpuUsage.toFixed(1) + "%"
                    color: statsPanel.gpuColor
                    font.pixelSize: 11
                    font.bold: true
                }
                Text {
                    visible: SystemStats.busiestCoreUsage > 0
                    text: qsTr("· busiest core") + " " + SystemStats.busiestCoreUsage + "%"
                    color: "#8ea0ae"
                    font.pixelSize: 11
                }
                Text {
                    visible: SystemStats.gpuDecodeUsage > 0.05
                    text: qsTr("· decode") + " " + SystemStats.gpuDecodeUsage.toFixed(0) + "%"
                    color: "#9ecbff"
                    font.pixelSize: 11
                }
            }

            Canvas {
                id: usageCanvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 32
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d");
                    statsPanel.paintGrid(ctx, width, height);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.cpuHistory, 0, 100, statsPanel.cpuColor, true);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.gpuHistory, 0, 100, statsPanel.gpuColor, false);
                }
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: tempLabels.implicitHeight

                RowLayout {
                    id: tempLabels
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 12

                    Text {
                        id: tempCpuText
                        visible: SystemStats.cpuTemperature >= 0
                        text: SystemStats.cpuTemperatureLabel + " " + statsPanel.formatTemp(SystemStats.cpuTemperature, generalSettings.statsTemperatureUnit)
                        color: statsPanel.tempCpuColor
                        font.pixelSize: 11
                        font.bold: true
                    }
                    Text {
                        id: tempGpuText
                        visible: SystemStats.gpuTemperature >= 0
                        text: SystemStats.gpuTemperatureLabel + " " + statsPanel.formatTemp(SystemStats.gpuTemperature, generalSettings.statsTemperatureUnit)
                        color: statsPanel.tempGpuColor
                        font.pixelSize: 11
                        font.bold: true
                    }
                    Text {
                        id: tempDiskText
                        visible: SystemStats.diskTemperature >= 0
                        text: SystemStats.diskTemperatureLabel + " " + statsPanel.formatTemp(SystemStats.diskTemperature, generalSettings.statsTemperatureUnit)
                        color: statsPanel.tempDiskColor
                        font.pixelSize: 11
                        font.bold: true
                    }
                    Text {
                        visible: !tempCpuText.visible && !tempGpuText.visible && !tempDiskText.visible
                        text: qsTr("Temperature unavailable")
                        color: "#8ea0ae"
                        font.pixelSize: 11
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: containsMouse && tempSensorTip.length > 0
                    ToolTip.text: tempSensorTip
                    property string tempSensorTip: {
                        var parts = [];
                        if (SystemStats.cpuTemperature >= 0 && SystemStats.cpuTemperatureDetail.length)
                            parts.push(SystemStats.cpuTemperatureDetail);
                        if (SystemStats.gpuTemperature >= 0 && SystemStats.gpuTemperatureDetail.length)
                            parts.push(SystemStats.gpuTemperatureDetail);
                        if (SystemStats.diskTemperature >= 0 && SystemStats.diskTemperatureDetail.length)
                            parts.push(SystemStats.diskTemperatureDetail);
                        return parts.join("\n");
                    }
                }
            }

            Canvas {
                id: tempCanvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 32
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d");
                    var lo = statsPanel.tempScaleLo();
                    var hi = statsPanel.tempScaleHi();
                    statsPanel.paintGrid(ctx, width, height);
                    statsPanel.paintTempGuide(ctx, width, height);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.displaySeries(statsPanel.tempDiskHistory), lo, hi, statsPanel.tempDiskColor, false);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.displaySeries(statsPanel.tempGpuHistory), lo, hi, statsPanel.tempGpuColor, false);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.displaySeries(statsPanel.tempCpuHistory), lo, hi, statsPanel.tempCpuColor, false);
                }
            }

            Text {
                text: qsTr("LNG_00202") + (SystemStats.netUsage >= 1.0 ? SystemStats.netUsage.toFixed(1) + " Mbps" : (SystemStats.netUsage * 1000.0).toFixed(0) + " kbps")
                color: statsPanel.netColor
                font.pixelSize: 11
                font.bold: true
            }

            Canvas {
                id: netCanvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 32
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d");
                    statsPanel.paintGrid(ctx, width, height);
                    statsPanel.paintSeries(ctx, width, height, statsPanel.netHistory, 0, statsPanel.netScaleHi(), statsPanel.netColor, true);
                }
            }
        }

        Connections {
            target: generalSettings
            function onStatsTemperatureUnitChanged() {
                tempCanvas.requestPaint();
            }
        }

        // Resize Handlers (Self-contained self-mapping MouseAreas)
        MouseArea {
            id: resizeLeft
            width: 6
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 6
            anchors.bottomMargin: 6
            cursorShape: Qt.SizeHorCursor
            z: 10
            property real clickX: 0
            property real initX: 0
            property real initW: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                initX = statsPanel.x
                initW = statsPanel.width
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var newWidth = initW - deltaX
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.x = initX + deltaX
                        statsPanel.width = newWidth
                    }
                }
            }
        }

        MouseArea {
            id: resizeRight
            width: 6
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 6
            anchors.bottomMargin: 6
            cursorShape: Qt.SizeHorCursor
            z: 10
            property real clickX: 0
            property real initW: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                initW = statsPanel.width
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var newWidth = initW + deltaX
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.width = newWidth
                    }
                }
            }
        }

        MouseArea {
            id: resizeTop
            height: 6
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            cursorShape: Qt.SizeVerCursor
            z: 10
            property real clickY: 0
            property real initY: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickY = p.y
                initY = statsPanel.y
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaY = p.y - clickY
                    var newHeight = initH - deltaY
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.y = initY + deltaY
                        statsPanel.height = newHeight
                    }
                }
            }
        }

        MouseArea {
            id: resizeBottom
            height: 6
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            cursorShape: Qt.SizeVerCursor
            z: 10
            property real clickY: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickY = p.y
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaY = p.y - clickY
                    var newHeight = initH + deltaY
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.height = newHeight
                    }
                }
            }
        }

        MouseArea {
            id: resizeTopLeft
            width: 8
            height: 8
            anchors.left: parent.left
            anchors.top: parent.top
            cursorShape: Qt.SizeFDiagCursor
            z: 10
            property real clickX: 0
            property real clickY: 0
            property real initX: 0
            property real initY: 0
            property real initW: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                clickY = p.y
                initX = statsPanel.x
                initY = statsPanel.y
                initW = statsPanel.width
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var deltaY = p.y - clickY
                    var newWidth = initW - deltaX
                    var newHeight = initH - deltaY
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.x = initX + deltaX
                        statsPanel.width = newWidth
                    }
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.y = initY + deltaY
                        statsPanel.height = newHeight
                    }
                }
            }
        }

        MouseArea {
            id: resizeTopRight
            width: 8
            height: 8
            anchors.right: parent.right
            anchors.top: parent.top
            cursorShape: Qt.SizeBDiagCursor
            z: 10
            property real clickX: 0
            property real clickY: 0
            property real initY: 0
            property real initW: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                clickY = p.y
                initY = statsPanel.y
                initW = statsPanel.width
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var deltaY = p.y - clickY
                    var newWidth = initW + deltaX
                    var newHeight = initH - deltaY
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.width = newWidth
                    }
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.y = initY + deltaY
                        statsPanel.height = newHeight
                    }
                }
            }
        }

        MouseArea {
            id: resizeBottomLeft
            width: 8
            height: 8
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            cursorShape: Qt.SizeBDiagCursor
            z: 10
            property real clickX: 0
            property real clickY: 0
            property real initX: 0
            property real initW: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                clickY = p.y
                initX = statsPanel.x
                initW = statsPanel.width
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var deltaY = p.y - clickY
                    var newWidth = initW - deltaX
                    var newHeight = initH + deltaY
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.x = initX + deltaX
                        statsPanel.width = newWidth
                    }
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.height = newHeight
                    }
                }
            }
        }

        MouseArea {
            id: resizeBottomRight
            width: 8
            height: 8
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            cursorShape: Qt.SizeFDiagCursor
            z: 10
            property real clickX: 0
            property real clickY: 0
            property real initW: 0
            property real initH: 0
            onPressed: {
                var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                clickX = p.x
                clickY = p.y
                initW = statsPanel.width
                initH = statsPanel.height
            }
            onPositionChanged: {
                if (pressed) {
                    var p = mapToItem(statsPanel.parent, mouse.x, mouse.y)
                    var deltaX = p.x - clickX
                    var deltaY = p.y - clickY
                    var newWidth = initW + deltaX
                    var newHeight = initH + deltaY
                    if (newWidth >= statsPanel.minWidth) {
                        statsPanel.width = newWidth
                    }
                    if (newHeight >= statsPanel.minHeight) {
                        statsPanel.height = newHeight
                    }
                }
            }
        }
    }

    // Loading overlay for auxiliary window
    Rectangle {
        id: loadingOverlay
        anchors.centerIn: parent
        width: loadingRow.implicitWidth + 40
        height: loadingRow.implicitHeight + 24
        color: "#cc121214"
        border.color: "#00f5d4"
        border.width: 1.5
        radius: 8
        z: 999999
        visible: loadingTimer.running

        RowLayout {
            id: loadingRow
            anchors.centerIn: parent
            spacing: 16

            Image {
                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2.5' stroke-linecap='round'><path d='M12 2a10 10 0 1 0 10 10'></path></svg>"
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                fillMode: Image.PreserveAspectFit

                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                    running: loadingOverlay.visible
                }
            }

            Text {
                text: qsTr("LNG_00201")
                color: "white"
                font.bold: true
                font.pixelSize: 13
            }
        }
    }

    Timer {
        id: loadingTimer
        interval: 2000
        repeat: false
    }

    Loader {
        id: playbackWindowLoader
        active: false
        onLoaded: {
            item.show();
            item.raise();
        }
    }

    // Tracks mouse idleness so the viewport info badges can be hidden like the cursor is
    QtObject {
        id: infoIdleState
        property bool idle: false
    }

    Connections {
        target: viewSettings
        function onHideInfoBadgesWhenIdleChanged() {
            infoIdleState.idle = false;
            infoIdleTimer.restart();
        }
    }

    Timer {
        id: infoIdleTimer
        running: viewSettings.hideInfoBadgesWhenIdle
        interval: 3000
        onTriggered: infoIdleState.idle = true
    }

    EventFilter {
        enabled: viewSettings.hideInfoBadgesWhenIdle
        scope: EventFilter.Application
        eventTypes: [ "MouseMove", "MouseButtonPress" ]
        eventProperties: false
        onEventFiltered: {
            infoIdleState.idle = false;
            infoIdleTimer.restart();
        }
    }

    CursorShape {
        id: cursorShape

        autoHide: rootWindow.activeFocusItem != null && // Disabled when ApplicationWindow isn't active
                  ((Context.config.fullScreen && viewSettings.hideCursorWhenFullScreen) ||
                   (!Context.config.fullScreen && viewSettings.hideCursorWhenWindowed))
        autoHideTimeout: 3000
        anchors.fill: parent
    }

    // Click menu for the background logging icon: says what is wrong and offers a restart.
    Menu {
        id: bgLogMenu
        MenuItem {
            enabled: false
            text: HikvisionEventLogger.backgroundText !== "" ? HikvisionEventLogger.backgroundText : qsTr("Background logging: checking...")
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Restart background logging")
            enabled: !HikvisionEventLogger.backgroundRestarting
            onTriggered: {
                rootWindow.showNotice(qsTr("Restarting background logging..."), "#00f5d4", 0);
                HikvisionEventLogger.restartBackground(Context.config.fileName);
            }
        }
    }

    Connections {
        target: HikvisionEventLogger
        onBackgroundAutoRestarted: {
            if (error === "")
                rootWindow.showNotice(qsTr("Background logging had stopped and was restarted automatically"), "#ff9f43", 8000);
            else
                rootWindow.showNotice(qsTr("Background logging is down and could not be restarted: %1").arg(error), "#ff3333", 10000);
        }
        onBackgroundRestartFinished: {
            if (error === "")
                rootWindow.showNotice(qsTr("Background logging restarted"), "#00ff66", 5000);
            else
                rootWindow.showNotice(qsTr("Could not restart background logging: %1").arg(error), "#ff3333", 10000);
        }
    }

    // Small status popup for long-running actions. holdMs <= 0 keeps it up until replaced.
    function showNotice(text, color, holdMs) {
        noticeText.text = text;
        noticeText.color = color;
        notice.border.color = color;
        notice.opacity = 1.0;
        if (holdMs > 0) {
            noticeHideTimer.interval = holdMs;
            noticeHideTimer.restart();
        } else {
            noticeHideTimer.stop();
        }
    }

    Timer {
        id: noticeHideTimer
        onTriggered: notice.opacity = 0.0
    }

    // The status notice is a window of its own, not an item in this window: the Settings window (where Camera Tools is) and the
    // other windows are separate windows that sit on top of this one, and an item here would be hidden behind them. It never takes
    // the focus or the clicks, so the window under it carries on working.
    Window {
        id: noticeWindow
        readonly property real maxWidth: Math.max(200, rootWindow.width - 40)
        flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus | Qt.WindowTransparentForInput
        color: "transparent"
        visible: notice.opacity > 0.01 && rootWindow.visibility !== Window.Minimized && rootWindow.visible
        width: notice.width
        height: notice.height
        x: Math.round(rootWindow.x + (rootWindow.width - width) / 2)
        y: Math.round(rootWindow.y + rootWindow.height - height - 76)

        Rectangle {
            id: notice
            width: Math.min(noticeWindow.maxWidth, noticeText.implicitWidth + 36)
            height: noticeText.implicitHeight + 18
            radius: 10
            color: "#f2121214"
            border.color: "#00f5d4"
            border.width: 1
            opacity: 0.0

            Behavior on opacity {
                NumberAnimation { duration: 160 }
            }

            Text {
                id: noticeText
                anchors.centerIn: parent
                width: Math.min(implicitWidth, noticeWindow.maxWidth - 36)
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: "#00f5d4"
                font.bold: true
                font.pixelSize: 12
            }
        }
    }

    Rectangle {
        id: layoutToast
        z: 1000000
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
        width: layoutToastText.implicitWidth + 36
        height: layoutToastText.implicitHeight + 16
        radius: 16
        color: "#e6121214"
        border.color: "#00f5d4"
        border.width: 1
        opacity: 0.0
        visible: opacity > 0.01

        Behavior on opacity {
            NumberAnimation { duration: 160 }
        }

        Text {
            id: layoutToastText
            anchors.centerIn: parent
            color: "#00f5d4"
            font.bold: true
            font.pixelSize: 13
            font.capitalization: Font.AllUppercase
        }
    }

}
