import QtQml 2.11
import QtQuick 2.11
import QtQuick.Controls 2.4
import QtQuick.Layouts 1.11
import QtMultimedia 5.11
import Qt.labs.settings 1.0
import CCTV_Viewer.Multimedia 1.0
import CCTV_Viewer.Hikvision 1.0
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Themes 1.0
import Qt.labs.platform 1.1 as Platform
import QtGraphicalEffects 1.0

FocusScope {
    id: root

    Behavior on scale {
        enabled: typeof viewSettings !== "undefined" ? !viewSettings.disableViewportZoomAnimation : true
        NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
    }
    Behavior on x {
        enabled: typeof viewSettings !== "undefined" ? !viewSettings.disableViewportZoomAnimation : true
        NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
    }
    Behavior on y {
        enabled: typeof viewSettings !== "undefined" ? !viewSettings.disableViewportZoomAnimation : true
        NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
    }

    property string color: "black"
    property bool ptzPadVisible: false

    // --- Point the camera at a box drawn on the wide lens (3D positioning of a two-lens PTZ camera) ---
    property bool isAimMode: false   // the next drag on the picture is sent to the camera
    property bool aimWide: false     // this tile's lens takes a drawn box (the "3D" badge shows)
    property bool aimIsWide: false   // ... and it is the wide lens of a two-lens PTZ (a box picks a spot in the whole scene)
    property var aimTarget: null     // { ip, http, channel, user, pass } of the camera and its own wide-lens channel
    property bool aimSent: false     // this tile sent the last box
    property string aimMessage: ""
    property bool aimFailed: false
    property string aimWideFor: ""   // which camera and channel aimWide was worked out for
    property string aimCheckedFor: "" // which camera and channel has been asked about already
    onIsZoomSelectionModeChanged: if (isZoomSelectionMode) isAimMode = false
    // A box drawn on a zoomed-in or 1:1 view would not match the camera's own picture, so the mode ends there.
    onIsZoomedChanged: if (isZoomed) isAimMode = false

    property bool isSubStream: false
    property int streamIndex: 1
    property string directCameraIp: ""
    property var streamIdCache: ({})
    property int stallBackoffMs: 0
    property double stallLastAttemptMs: 0
    property double streamAssignedAtMs: 0
    property string iFrameForcedUrl: ""
    property bool isOneToOne: false
    property real oneToOneX: 0
    property real oneToOneY: 0

    function videoFrameSize() {
        if (isQuickPlayback && quickPlaybackPlayerLoader.item &&
                quickPlaybackPlayerLoader.item.videoWidth > 0 &&
                quickPlaybackPlayerLoader.item.videoHeight > 0) {
            return Qt.size(quickPlaybackPlayerLoader.item.videoWidth,
                           quickPlaybackPlayerLoader.item.videoHeight);
        }
        var activeOutput = activePlayerIndex === 1 ? videoOutput1 : videoOutput2;
        if (activeOutput.sourceRect.width > 0 && activeOutput.sourceRect.height > 0) {
            return activeOutput.sourceRect;
        }
        return Qt.size(16, 9);
    }

    // A 4:3 picture (including the usual CCTV sizes such as 704x576 and 720x480) in a 16:9 tile is stretched to
    // fill the tile. A picture only a little wider than its tile, such as a panoramic that does not match
    // exactly, is stretched the other way to fill the tile. A picture more than about a third wider than the
    // tile keeps the bars above and below. A 16:9 picture in a matching tile keeps its own shape.
    function pictureIsFourByThree(frame) {
        if (!frame || frame.width < 16 || frame.height < 16)
            return false;
        var r = frame.width / frame.height;
        return r >= 1.18 && r <= 1.52;
    }
    function tileIsSixteenByNine() {
        var r = videoContainer.width / Math.max(1, videoContainer.height);
        return r >= 1.6 && r <= 2.05;
    }
    // True when filling the tile would make the picture no more than about a third taller than life.
    function pictureSlightlyWiderThanTile(frame) {
        if (!frame || frame.width < 16 || frame.height < 16)
            return false;
        if (videoContainer.width < 16 || videoContainer.height < 16)
            return false;
        var frameRatio = frame.width / frame.height;
        var tileRatio = videoContainer.width / videoContainer.height;
        if (tileRatio <= 0 || frameRatio <= tileRatio)
            return false;
        return frameRatio / tileRatio <= 1.34;
    }

    function fittedVideoRect() {
        var frame = videoFrameSize();
        if ((pictureIsFourByThree(frame) && tileIsSixteenByNine()) || pictureSlightlyWiderThanTile(frame))
            return Qt.rect(0, 0, videoContainer.width, videoContainer.height);
        var frameRatio = frame.width / Math.max(1, frame.height);
        var containerRatio = videoContainer.width / Math.max(1, videoContainer.height);
        if (frameRatio > containerRatio) {
            var fittedHeight = videoContainer.width / frameRatio;
            return Qt.rect(0, (videoContainer.height - fittedHeight) / 2,
                           videoContainer.width, fittedHeight);
        }
        var fittedWidth = videoContainer.height * frameRatio;
        return Qt.rect((videoContainer.width - fittedWidth) / 2, 0,
                       fittedWidth, videoContainer.height);
    }

    onIsOneToOneChanged: {
        if (isOneToOne)
            isAimMode = false; // a box drawn at 1:1 would not match the camera's picture
        if (isOneToOne) {
            var videoW = 1280;
            var videoH = 720;
            if (isQuickPlayback && quickPlaybackPlayerLoader.item) {
                videoW = quickPlaybackPlayerLoader.item.videoWidth > 0 ? quickPlaybackPlayerLoader.item.videoWidth : 1280;
                videoH = quickPlaybackPlayerLoader.item.videoHeight > 0 ? quickPlaybackPlayerLoader.item.videoHeight : 720;
            } else {
                var activeOutput = activePlayerIndex === 1 ? videoOutput1 : videoOutput2;
                videoW = activeOutput.sourceRect.width > 0 ? activeOutput.sourceRect.width : 1280;
                videoH = activeOutput.sourceRect.height > 0 ? activeOutput.sourceRect.height : 720;
            }
            oneToOneX = Math.min(0, (videoContainer.width - videoW) / 2);
            oneToOneY = Math.min(0, (videoContainer.height - videoH) / 2);
        } else {
            oneToOneX = 0;
            oneToOneY = 0;
        }
    }

    property var avOptions: ({})
    property bool ignoreGlobalAVFormatOptions: false
    property int index: -1
    property bool isFullScreen: false
    property var layoutModel: null

    property int loops: 1
    onLoopsChanged: {
        qmlAvPlayer1.loops = loops;
        qmlAvPlayer2.loops = loops;
    }
    
    property int activePlayerIndex: 1
    property string activeCameraId: ""
    property string activeStreamUrl: ""
    
    readonly property var playbackState: activePlayerIndex === 1 ? qmlAvPlayer1.playbackState : qmlAvPlayer2.playbackState
    readonly property var status: activePlayerIndex === 1 ? qmlAvPlayer1.status : qmlAvPlayer2.status
    readonly property bool activeIsSubStream: activePlayerIndex === 1 ? qmlAvPlayer1.isSubStreamOfPlayer : qmlAvPlayer2.isSubStreamOfPlayer
    property string source: ""
    
    readonly property bool isHikvision: String(source).indexOf("hikvision://") !== -1
    property string recorderIp: ""
    property int recorderPort: 8000
    property int sdkPort: 8000
    property int httpPort: 80
    property int rtspPort: 554
    property string rtspTransport: ""
    property string username: ""
    property string password: ""
    property int channelId: 1

    property bool isZoomed: false
    property bool isZoomSelectionMode: false
    // A single camera filling the view (maximized, or a 1x1 layout) can be boxed again to zoom tighter.
    property bool tightenOnDrag: false
    property real zoomX: 0
    property real zoomY: 0
    property real zoomWidth: 1
    property real zoomHeight: 1

    // x1,y1,w,h are in this item's coordinates. A box on the full picture sets the view.
    // A box drawn while already zoomed is a fraction of that view, so it zooms tighter.
    function zoomToBox(x1, y1, w, h) {
        var fr = fittedVideoRect();
        if (fr.width <= 1 || fr.height <= 1)
            return false;
        var nx1 = Math.max(0, Math.min(1, (x1 - fr.x) / fr.width));
        var ny1 = Math.max(0, Math.min(1, (y1 - fr.y) / fr.height));
        var nx2 = Math.max(0, Math.min(1, (x1 + w - fr.x) / fr.width));
        var ny2 = Math.max(0, Math.min(1, (y1 + h - fr.y) / fr.height));
        var nw = nx2 - nx1;
        var nh = ny2 - ny1;
        if (nw <= 0.01 || nh <= 0.01)
            return false;
        // Equal fractions keep the picture's aspect ratio. The smaller side grows so the whole box stays visible.
        var view = Math.max(nw, nh);
        var left = (nx1 + nx2) / 2 - view / 2;
        var top = (ny1 + ny2) / 2 - view / 2;
        if (isZoomed) {
            left = zoomX + left * zoomWidth;
            top = zoomY + top * zoomHeight;
            view = view * Math.max(zoomWidth, zoomHeight);
        }
        view = Math.max(0.02, Math.min(1, view));
        zoomX = Math.max(0, Math.min(1 - view, left));
        zoomY = Math.max(0, Math.min(1 - view, top));
        zoomWidth = view;
        zoomHeight = view;
        isZoomed = true;
        isZoomSelectionMode = false;
        return true;
    }

    // Slide the current box zoom. dx/dy are pixels in this item's coordinates.
    function panZoomBy(dx, dy) {
        if (!isZoomed)
            return;
        var panRect = fittedVideoRect();
        var dZoomX = (dx / Math.max(1, panRect.width)) * zoomWidth;
        var dZoomY = (dy / Math.max(1, panRect.height)) * zoomHeight;
        zoomX = Math.max(0, Math.min(1 - zoomWidth, zoomX - dZoomX));
        zoomY = Math.max(0, Math.min(1 - zoomHeight, zoomY - dZoomY));
    }

    // Zoom the ROI (box) zoom in/out with the mouse wheel, keeping the point under the cursor fixed.
    // px/py are in this item's coordinates. Zooming out to the full picture clears the zoom.
    function zoomByWheel(angleDeltaY, px, py) {
        if (!isZoomed || angleDeltaY === 0) return;
        var fr = fittedVideoRect();
        var u = Math.max(0, Math.min(1, (px - fr.x) / Math.max(1, fr.width)));
        var v = Math.max(0, Math.min(1, (py - fr.y) / Math.max(1, fr.height)));
        var factor = Math.pow(0.75, angleDeltaY / 120); // wheel up => smaller visible region => zoom in
        var newW = Math.max(0.05, Math.min(1, zoomWidth * factor));
        var newH = Math.max(0.05, Math.min(1, zoomHeight * factor));
        if (newW >= 0.999 && newH >= 0.999) {
            isZoomed = false;
            zoomX = 0;
            zoomY = 0;
            zoomWidth = 1;
            zoomHeight = 1;
            return;
        }
        var vx = zoomX + u * zoomWidth;
        var vy = zoomY + v * zoomHeight;
        zoomWidth = newW;
        zoomHeight = newH;
        zoomX = Math.max(0, Math.min(1 - newW, vx - u * newW));
        zoomY = Math.max(0, Math.min(1 - newH, vy - v * newH));
    }

    property bool isQuickPlayback: false
    property var quickPlaybackActivationTime: null
    property int quickPlaybackOffset: 1740
    property int quickPlaybackSpeed: 1
    property bool isQuickPlaybackPaused: false
    property var quickPlaybackSegments: []
    property var quickPlaybackEvents: []
    property bool pendingQuickPlaybackSeek: false
    property bool isRestoringLiveView: false

    Timer {
        id: restoringLiveViewTimer
        interval: 3000
        repeat: false
        onTriggered: root.isRestoringLiveView = false
    }

    Timer {
        id: seamlessSwitchTimer
        interval: 100
        repeat: false
        property int targetPlayerIndex: -1
        onTriggered: {
            if (targetPlayerIndex === -1 || targetPlayerIndex === activePlayerIndex) return;
            var player = targetPlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
            var oldPlayer = targetPlayerIndex === 1 ? qmlAvPlayer2 : qmlAvPlayer1;
            
            // Sanity check: Ensure target player is still healthy and matches activeStreamUrl
            if (String(player.source) !== activeStreamUrl || player.playbackState !== MediaPlayer.PlayingState) {
                console.log("[Player] Seamless switch aborted: Target player " + targetPlayerIndex + " is no longer valid or matches target URL.");
                return;
            }
            
            console.log("[Player] Seamless switch timer triggered: Switching activePlayerIndex from " + activePlayerIndex + " to " + targetPlayerIndex);
            
            oldPlayer.muted = true;
            player.muted = root.muted;
            activePlayerIndex = targetPlayerIndex;
            
            var targetIndex = targetPlayerIndex;
            Qt.callLater(function() {
                if (activePlayerIndex === targetIndex) {
                    console.log("[Player] Post-switch (timer): stopping and clearing old player source");
                    oldPlayer.source = "";
                    oldPlayer.isSubStreamOfPlayer = false;
                }
            });
        }
    }

    Timer {
        id: stallWatchTimer
        interval: 1000
        repeat: true
        running: root.activeStreamUrl !== "" && !root.isQuickPlayback && !root.recorderOffline && !root.liveSuspended
        onTriggered: root.checkStall()
    }

    Connections {
        target: HikvisionManager
        function onStreamingChannelsReady(ip, xml) {
            root.applyStreamXml(ip, xml);
        }
    }

    function getDateKey(d) {
        if (!d) return "";
        return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate();
    }

    function formatTime(date) {
        if (!date) return "--:--:--";
        return Qt.formatTime(date, "HH:mm:ss");
    }

    function formatRelativeTime(offsetSeconds) {
        var diff = 1800 - offsetSeconds;
        if (diff === 0) return "now";
        var m = Math.floor(diff / 60);
        var s = diff % 60;
        return "-" + (m < 10 ? "0" + m : m) + ":" + (s < 10 ? "0" + s : s);
    }

    function updateQuickPlaybackSegments() {
        if (!isQuickPlayback || !quickPlaybackActivationTime || !rootWindow) return;
        var dateKey = getDateKey(quickPlaybackActivationTime);
        var cacheKey = recorderIp + "_" + channelId + "_" + dateKey;
        var segments = rootWindow.playbackSegmentsCache[cacheKey];
        if (segments) {
            quickPlaybackSegments = segments;
        } else {
            quickPlaybackSegments = [];
        }
    }

    function updateQuickPlaybackEvents() {
        if (!isQuickPlayback || !quickPlaybackActivationTime || !rootWindow) return;
        var cacheKey = recorderIp + "_" + channelId + "_" + getDateKey(quickPlaybackActivationTime);
        var events = rootWindow.playbackEventsCache[cacheKey];
        quickPlaybackEvents = events ? events : [];
    }

    onIsQuickPlaybackChanged: {
        if (isQuickPlayback) {
            quickPlaybackActivationTime = new Date();
            quickPlaybackOffset = 1740;
            quickPlaybackSpeed = 1;
            isQuickPlaybackPaused = false;
            pendingQuickPlaybackSeek = true;
            
            var recorderInfoForCam = {
                "ip": recorderIp,
                "port": sdkPort || recorderPort || 8000,
                "sdkPort": sdkPort || recorderPort || 8000,
                "httpPort": httpPort || 80,
                "rtspPort": rtspPort || 554,
                "username": username,
                "password": password
            };
            var start = new Date(quickPlaybackActivationTime);
            start.setHours(0,0,0,0);
            start.setDate(start.getDate() - 1);
            var end = new Date(quickPlaybackActivationTime);
            end.setHours(23,59,59,999);
            end.setDate(end.getDate() + 1);
            
            updateQuickPlaybackSegments();
            updateQuickPlaybackEvents();
            HikvisionISAPI.searchRecordings(recorderInfoForCam, channelId, start, end);
            HikvisionISAPI.searchEvents(recorderInfoForCam, channelId, start, end);
            
            // Playback will start in quickPlaybackPlayerLoader.onLoaded
            quickPlaybackTimer.start();
        } else {
            pendingQuickPlaybackSeek = false;
            quickPlaybackTimer.stop();
            isRestoringLiveView = true;
            restoringLiveViewTimer.restart();
        }
        updateSource();
    }

    Connections {
        target: HikvisionISAPI
        function onEventsFinished(eventRecorderIp, eventChannelId, startTime, segments) {
            if (!root.isQuickPlayback || eventRecorderIp !== root.recorderIp || eventChannelId !== root.channelId)
                return;
            var targetDate = new Date(startTime);
            targetDate.setDate(targetDate.getDate() + 1);
            var cacheKey = eventRecorderIp + "_" + eventChannelId + "_" + root.getDateKey(targetDate);
            var adjustedEvents = [];
            if (segments) {
                for (var i = 0; i < segments.length; i++) {
                    var seg = segments[i];
                    var localOffsetMs = seg.timeIsLocal ? 0 : new Date(seg.startTime).getTimezoneOffset() * 60000;
                    adjustedEvents.push({
                        "startTime": seg.startTime + localOffsetMs,
                        "endTime": seg.endTime + localOffsetMs,
                        "event": true,
                        "kind": seg.kind || "motion"
                    });
                }
            }
            adjustedEvents = rootWindow.mergeLogEvents(eventRecorderIp, eventChannelId, startTime.getTime ? startTime.getTime() : new Date(startTime).getTime(), adjustedEvents);
            if (typeof rootWindow !== "undefined" && rootWindow) {
                var tempEvents = Object.assign({}, rootWindow.playbackEventsCache);
                tempEvents[cacheKey] = adjustedEvents;
                rootWindow.playbackEventsCache = tempEvents;
            }
            root.updateQuickPlaybackEvents();
        }
        function onSearchFinished(searchRecorderIp, searchChannelId, startTime, segments) {
            if (root.isQuickPlayback && searchRecorderIp === root.recorderIp && searchChannelId === root.channelId) {
                var targetDate = new Date(startTime);
                targetDate.setDate(targetDate.getDate() + 1);
                var dateKey = root.getDateKey(targetDate);
                var cacheKey = searchRecorderIp + "_" + searchChannelId + "_" + dateKey;

                var adjustedSegments = [];
                if (segments) {
                    for (var i = 0; i < segments.length; i++) {
                        var seg = segments[i];
                        var localOffsetMs = new Date(seg.startTime).getTimezoneOffset() * 60000;
                        adjustedSegments.push({
                            "startTime": seg.startTime + localOffsetMs,
                            "endTime": seg.endTime + localOffsetMs
                        });
                    }
                }
                
                if (typeof rootWindow !== "undefined" && rootWindow) {
                    var tempSegments = Object.assign({}, rootWindow.playbackSegmentsCache);
                    tempSegments[cacheKey] = adjustedSegments;
                    rootWindow.playbackSegmentsCache = tempSegments;
                }
                root.updateQuickPlaybackSegments();

                if (root.pendingQuickPlaybackSeek) {
                    root.pendingQuickPlaybackSeek = false;
                    if (adjustedSegments.length > 0 && root.quickPlaybackActivationTime) {
                        var windowEnd = root.quickPlaybackActivationTime.getTime();
                        var windowStart = windowEnd - 1800000;
                        var maxEndTime = 0;
                        for (var i = 0; i < adjustedSegments.length; i++) {
                            var seg = adjustedSegments[i];
                            if (seg.startTime < windowEnd && seg.endTime > windowStart) {
                                var overlapEnd = Math.min(windowEnd, seg.endTime);
                                if (overlapEnd > maxEndTime) {
                                    maxEndTime = overlapEnd;
                                }
                            }
                        }
                        if (maxEndTime > 0) {
                            var targetPlayTime = maxEndTime - 60 * 1000; // 60 seconds before latest record
                            if (targetPlayTime < windowStart) {
                                targetPlayTime = windowStart;
                            }
                            var newOffset = Math.floor((targetPlayTime - windowStart) / 1000);
                            root.quickPlaybackOffset = newOffset;
                            console.log("[Player QML] Aligning quick playback start time to:", new Date(targetPlayTime), "with offset:", newOffset);
                            if (quickPlaybackPlayerLoader.item) {
                                quickPlaybackPlayerLoader.item.playAtTime(new Date(targetPlayTime));
                            }
                        } else {
                            console.log("[Player QML] No overlapping segments found in the 30-minute window.");
                        }
                    } else {
                        console.log("[Player QML] Search completed but no segments found for channel:", root.channelId);
                    }
                }
            }
        }
    }

    // Lookup names from the globally saved recorders JSON
    property string cameraNameInfo: {
        if (!isHikvision || !recorderIp) return "";
        try {
            var jsonStr = rootWindow.hikvisionRecordersJson;
            if (!jsonStr) return "";
            var recordersList = JSON.parse(jsonStr);
            for (var i = 0; i < recordersList.length; ++i) {
                var rec = recordersList[i];
                if (rec.ip === recorderIp) {
                    var recName = rec.name ? rec.name : rec.ip;
                    var camName = "";
                    if (rec.cameras) {
                        for (var j = 0; j < rec.cameras.length; ++j) {
                            if (parseInt(rec.cameras[j].channelId) === channelId) {
                                camName = rec.cameras[j].customName || rec.cameras[j].name || "";
                                break;
                            }
                        }
                    }
                    if (!camName) {
                        camName = "Camera " + channelId;
                    }
                    return recName + " Ch. " + channelId + " " + camName;
                }
            }
        } catch (e) {
            console.log("Error looking up camera names:", e);
        }
        return recorderIp + " Ch. " + channelId;
    }
    
    onSourceChanged: {
        Qt.callLater(updateSource);
    }

    // The user set this tile's recorder offline (its network is not connected): no stream, no detection watch, no retries.
    readonly property bool recorderOffline: {
        var rev = NvrStatusManager.offlineRevision; // re-evaluate when the offline set changes
        return root.isHikvision && root.recorderIp !== "" && NvrStatusManager.isAddressOffline(root.recorderIp);
    }
    // Archive playback uses its own connection. While it is open, drop this tile's live
    // stream the same way a hidden tile does, so a full grid does not stutter the recording.
    readonly property bool liveSuspended: (typeof rootWindow !== "undefined") && rootWindow.isPlaybackWindowOpen
                                          && (typeof generalSettings !== "undefined") && generalSettings.pauseLiveDuringPlayback
    onLiveSuspendedChanged: {
        if (liveSuspended) {
            timer.stop();
            qmlAvPlayer1.autoPlay = false;
            qmlAvPlayer2.autoPlay = false;
        } else {
            // Keep the held picture until the live stream's next frame replaces it.
            qmlAvPlayer1.holdLastFrame = true;
            qmlAvPlayer2.holdLastFrame = true;
            if (visible && !timer.running)
                timer.start();
        }
        Qt.callLater(updateSource);
        Qt.callLater(updateTargetWatch);
    }

    onRecorderOfflineChanged: {
        if (recorderOffline) {
            console.log("[Offline] tile " + root.index + ": recorder " + root.recorderIp + " is offline, stream stopped");
        }
        Qt.callLater(updateSource);
        Qt.callLater(updateTargetWatch);
    }

    onIsSubStreamChanged: {
        Qt.callLater(updateSource);
    }

    onStreamIndexChanged: {
        Qt.callLater(updateSource);
    }

    // Shared Hikvision Settings to sync real/mock stream toggle in real-time
    Settings {
        id: hikPlayerSettings
        fileName: Context.config.fileName
        category: "Hikvision"
        property bool useRealStreams: true

        onUseRealStreamsChanged: {
            updateSource();
        }
    }

    // True when this tile's camera is ticked in Settings > Audio > Choose cameras.
    readonly property bool aacRepairHere: {
        if (typeof generalSettings === "undefined" || root.recorderIp === "")
            return false;
        try {
            var l = JSON.parse(generalSettings.repairAacCameras || "[]");
            return Array.isArray(l) && l.indexOf(root.nvrKey()) >= 0;
        } catch (e) {
            return false;
        }
    }
    // True only while this tile's live Hikvision URL is going through the local relay.
    property bool aacRepairLive: false
    onAacRepairHereChanged: updateSource()

    function hikvisionStreamId(host, channel, index, streamHttpPort) {
        var wanted = Math.max(1, index);
        var fallback = channel * 100 + wanted;
        if (!host)
            return fallback;
        var cacheKey = host + ":" + channel;
        var ids = streamIdCache[cacheKey];
        if (!ids) {
            if (username)
                HikvisionManager.fetchStreamingChannelsAsync(host, streamHttpPort || 80, username, password);
            return fallback;
        }
        function ending(suffix) {
            for (var i = 0; i < ids.length; ++i) {
                if (ids[i] % 100 === suffix)
                    return ids[i];
            }
            return 0;
        }
        // 01 is the main stream and 02 the substream. Some recorders publish
        // only a main stream plus an unplayable extra id, so a grid must not
        // treat that extra id as the substream.
        if (wanted === 1)
            return ending(1) || ids[0] || fallback;
        if (wanted === 2)
            return ending(2) || ending(1) || fallback;
        return ids[wanted - 1] || fallback;
    }

    function applyStreamXml(ip, xml) {
        if (!ip || !xml || xml.length === 0)
            return;
        if (ip !== recorderIp && ip !== directCameraIp)
            return;
        var matches = String(xml).match(/<id>(\d+)<\/id>/g) || [];
        var byChan = {};
        for (var i = 0; i < matches.length; ++i) {
            var id = parseInt(matches[i].replace(/[^0-9]/g, ""));
            if (!(id > 0))
                continue;
            var ch = Math.floor(id / 100);
            if (!byChan[ch])
                byChan[ch] = [];
            if (byChan[ch].indexOf(id) < 0)
                byChan[ch].push(id);
        }
        var next = Object.assign({}, streamIdCache);
        var changed = false;
        for (var key in byChan) {
            byChan[key].sort(function(a, b) { return a - b; });
            var cacheKey = ip + ":" + key;
            var prev = next[cacheKey] ? next[cacheKey].join(",") : "";
            if (prev !== byChan[key].join(","))
                changed = true;
            next[cacheKey] = byChan[key];
        }
        streamIdCache = next;
        if (changed)
            updateSource();
    }

    function checkStall() {
        var player = activePlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
        if (!player)
            return;
        if (stallLastAttemptMs > 0 && player.lastFrameAtMs > stallLastAttemptMs) {
            stallBackoffMs = 0;
            stallLastAttemptMs = 0;
        }
        var enabled = activeStreamUrl !== "" && !root.isQuickPlayback && !root.recorderOffline
                && !root.liveSuspended && !player.holdLastFrame;
        var backoff = StallWatch.evaluate(enabled, player.status, player.lastFrameAtMs, streamAssignedAtMs,
                                           Date.now(), stallBackoffMs, stallLastAttemptMs);
        if (backoff <= 0)
            return;
        stallBackoffMs = backoff;
        stallLastAttemptMs = Date.now();
        iFrameForcedUrl = "";
        console.log("[Player] Stream quiet. Reconnecting " + activeCameraId);
        player.source = "";
        player.source = activeStreamUrl;
        player.play();
    }

    function updateSource() {
        // Learn the recorder address first: the Offline check below needs it, and a tile that has not read its address yet
        // would look online and ask the (unreachable) recorder a question that blocks the whole window for seconds.
        if (root.visible && !root.liveSuspended && !root.isQuickPlayback)
            parseUri(source);
        if (!root.visible || root.liveSuspended || root.isQuickPlayback || root.recorderOffline) {
            aacRepairLive = false;
            // Only the archive pause keeps the last picture. Hiding a tile, or a recorder
            // that is offline, still clears to black.
            if (root.liveSuspended) {
                if (qmlAvPlayer1.source != "")
                    qmlAvPlayer1.holdLastFrame = true;
                if (qmlAvPlayer2.source != "")
                    qmlAvPlayer2.holdLastFrame = true;
            }
            qmlAvPlayer1.source = "";
            qmlAvPlayer1.isSubStreamOfPlayer = false;
            qmlAvPlayer2.source = "";
            qmlAvPlayer2.isSubStreamOfPlayer = false;
            activeStreamUrl = "";
            activeCameraId = "";
            return;
        }

        aacRepairLive = false;
        var newUrl = "";
        var newCameraId = "";

        if (root.isQuickPlayback) {
            newUrl = "";
            newCameraId = "";
        } else if (!isHikvision) {
            newUrl = source;
            newCameraId = "viewport_" + root.index;
        } else if (hikPlayerSettings.useRealStreams) {
            var targetIp = recorderIp;
            var targetChannel = channelId;
            var targetRtspPort = rtspPort || 554;
            directCameraIp = "";
            if (streamIndex > 2) {
                // The camera list is read in the background. Until it arrives this stream stays on the recorder.
                var proxy = HikvisionManager.proxyCameraCached(recorderIp, httpPort || 80, username, password, channelId);
                if (proxy && proxy.ip && proxy.ip !== recorderIp) {
                    targetIp = proxy.ip;
                    targetChannel = proxy.channel || 1;
                    targetRtspPort = 554;
                    directCameraIp = targetIp;
                }
            }
            var streamHttp = (targetIp === recorderIp) ? (httpPort || 80) : 80;
            var streamId = hikvisionStreamId(targetIp, targetChannel, streamIndex, streamHttp);
            var creds = "";
            if (username) {
                creds = encodeURIComponent(username) + (password ? (":" + encodeURIComponent(password)) : "") + "@";
            }
            newUrl = "rtsp://" + creds + targetIp + ":" + targetRtspPort + "/Streaming/Channels/" + streamId;
            if (root.aacRepairHere) {
                newUrl = RtspAudioCompat.streamUrl(newUrl);
                aacRepairLive = true;
            }
            newCameraId = targetIp + "_" + targetChannel + "_" + streamId;
            console.log("[Player] Selected stream " + streamIndex + " channel " + channelId);
        }

        if (newUrl === "") {
            qmlAvPlayer1.source = "";
            qmlAvPlayer1.isSubStreamOfPlayer = false;
            qmlAvPlayer2.source = "";
            qmlAvPlayer2.isSubStreamOfPlayer = false;
            activeStreamUrl = "";
            activeCameraId = "";
            seamlessSwitchTimer.stop();
            return;
        }

        var activePlayer = activePlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
        var inactivePlayer = activePlayerIndex === 1 ? qmlAvPlayer2 : qmlAvPlayer1;

        if (activeStreamUrl === newUrl) {
            if (activePlayer.source === newUrl) {
                activePlayer.play();
            }
            return;
        }

        var isSameCamera = (newCameraId !== "" && newCameraId === activeCameraId && playbackState === MediaPlayer.PlayingState);

        if (isSameCamera) {
            console.log("[Player] Seamless switch quality of camera " + newCameraId + " to URL: " + newUrl);
            inactivePlayer.muted = true; // Keep inactive player muted during loading
            inactivePlayer.isSubStreamOfPlayer = root.isSubStream;
            inactivePlayer.source = newUrl;
            inactivePlayer.play();
            activeStreamUrl = newUrl;
            streamAssignedAtMs = Date.now();
            stallBackoffMs = 0;
            stallLastAttemptMs = 0;
        } else {
            console.log("[Player] Different camera: switching immediately to URL: " + newUrl);
            seamlessSwitchTimer.stop();
            activePlayerIndex = 1;
            qmlAvPlayer2.source = "";
            qmlAvPlayer2.isSubStreamOfPlayer = false;
            qmlAvPlayer1.isSubStreamOfPlayer = root.isSubStream;
            qmlAvPlayer1.source = newUrl;
            qmlAvPlayer1.play();
            activeStreamUrl = newUrl;
            activeCameraId = newCameraId;
            streamAssignedAtMs = Date.now();
            stallBackoffMs = 0;
            stallLastAttemptMs = 0;
        }
    }

    function checkSeamlessSwitch(playerIndex) {
        if (playerIndex === activePlayerIndex) {
            return;
        }
        
        var player = playerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
        if (String(player.source) !== activeStreamUrl) {
            console.log("[Player] checkSeamlessSwitch rejecting inactive player " + playerIndex + " due to source mismatch. Source: '" + player.source + "', Target: '" + activeStreamUrl + "'");
            return;
        }
        console.log("[Player] checkSeamlessSwitch checking inactive player " + playerIndex + " status: " + player.status + " hasVideo: " + player.hasVideo + " hasAudio: " + player.hasAudio + " framePresented: " + player.framePresented);
        if (player.playbackState === MediaPlayer.PlayingState && player.status === MediaPlayer.Buffered && player.hasVideo && player.framePresented) {
            if (seamlessSwitchTimer.running) {
                if (seamlessSwitchTimer.targetPlayerIndex === playerIndex) return;
                seamlessSwitchTimer.stop();
            }
            console.log("[Player] Inactive player " + playerIndex + " is ready. Starting 100ms seamless switch timer.");
            seamlessSwitchTimer.targetPlayerIndex = playerIndex;
            seamlessSwitchTimer.start();
        }
    }

    function handlePlayerStatus(playerIndex, status) {
        var statusPlayer = playerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
        // The new URL opens on the inactive player during a quality switch, and
        // that player does not become active until it is buffered. One I-frame
        // per URL, whichever player opened it.
        if ((status === MediaPlayer.LoadedMedia || status === MediaPlayer.Buffered)
                && String(statusPlayer.source) === root.activeStreamUrl
                && root.isHikvision && typeof HikvisionManager !== "undefined") {
            var isSub = statusPlayer.isSubStreamOfPlayer;
            if (root.activeStreamUrl !== "" && root.iFrameForcedUrl !== root.activeStreamUrl) {
                root.iFrameForcedUrl = root.activeStreamUrl;
                console.log("[Player] Stream " + (status === MediaPlayer.LoadedMedia ? "Loaded" : "Buffered") + ". Forcing I-Frame on camera: " + root.channelId + (isSub ? " sub" : " main"));
                HikvisionManager.forceIFrameAsync(root.recorderIp, root.recorderPort || 8000, root.username, root.password, root.channelId, isSub);
            }
        }

        if (status === MediaPlayer.InvalidMedia) {
            var failedUrl = String(playerIndex === 1 ? qmlAvPlayer1.source : qmlAvPlayer2.source);
            root.mediaError(failedUrl);
            if (root.directCameraIp !== "" && failedUrl.indexOf(root.directCameraIp) >= 0) {
                console.log("[Player] Camera " + root.directCameraIp + " rejected the NVR username or password. The camera login differs from recorder " + root.recorderIp + ".");
            }
        }

        if (playerIndex === activePlayerIndex) {
            return;
        }
        
        if (status === MediaPlayer.Buffered) {
            checkSeamlessSwitch(playerIndex);
        }
        else if (status === MediaPlayer.InvalidMedia) {
            console.log("[Player] Seamless switch failed: Inactive player " + playerIndex + " failed to load. Switching to show error.");
            activePlayerIndex = playerIndex;
            
            var targetIndex = playerIndex;
            Qt.callLater(function() {
                if (activePlayerIndex === targetIndex) {
                    var oldPlayer = targetIndex === 1 ? qmlAvPlayer2 : qmlAvPlayer1;
                    oldPlayer.source = "";
                    oldPlayer.isSubStreamOfPlayer = false;
                }
            });
        }
    }

    function updateMessageText() {
        var activePlayer = activePlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
        if (activePlayer.status === MediaPlayer.Buffered)
            root.isRestoringLiveView = false;
    }

    property bool muted: false
    property double volume: 1.0

    // The cell keeps this level so M can restore it after a mute from the tile button.
    function rememberAudible() {
        if (!(root.volume > 0))
            return;
        var cell = root.parent && root.parent.parent;
        if (cell)
            cell.audibleVolume = root.volume;
    }

    onTalkActiveHereChanged: {
        // Silence the camera's own audio on this tile while talking, so its microphone
        // does not pick up the speaker and howl. The previous state is restored afterwards.
        var p1 = qmlAvPlayer1, p2 = qmlAvPlayer2;
        if (talkActiveHere) {
            talkWasMuted = root.muted;
            p1.muted = true;
            p2.muted = true;
        } else {
            if (activePlayerIndex === 1) { p1.muted = talkWasMuted; p2.muted = true; }
            else { p2.muted = talkWasMuted; p1.muted = true; }
        }
    }
    property bool talkWasMuted: false
    readonly property bool hasAudio: {
        if (typeof generalSettings !== "undefined" && generalSettings.disableAudio)
            return false;
        // Quick playback stops the live stream, so the live player reports no audio.
        // The recording still has sound, and M has to be able to mute that tile.
        if (isQuickPlayback)
            return true;
        return activePlayerIndex === 1 ? qmlAvPlayer1.hasAudio : qmlAvPlayer2.hasAudio;
    }

    onMutedChanged: {
        if (activePlayerIndex === 1) {
            qmlAvPlayer1.muted = muted;
            qmlAvPlayer2.muted = true;
        } else {
            qmlAvPlayer2.muted = muted;
            qmlAvPlayer1.muted = true;
        }
    }

    onVolumeChanged: {
        qmlAvPlayer1.volume = volume;
        qmlAvPlayer2.volume = volume;
    }

    onActivePlayerIndexChanged: {
        if (activePlayerIndex === 1) {
            qmlAvPlayer1.muted = muted;
            qmlAvPlayer2.muted = true;
        } else {
            qmlAvPlayer2.muted = muted;
            qmlAvPlayer1.muted = true;
        }
    }

    onVisibleChanged: {
        // A preset-list reorder can hide and show this tile for a moment. Leave the stream running.
        if (typeof rootWindow !== "undefined" && rootWindow && rootWindow.layoutReorderHold)
            return;
        if (visible) {
            updateSource();
            if (!timer.running) {
                timer.start();
            }
        } else {
            timer.stop();
            qmlAvPlayer1.autoPlay = false;
            qmlAvPlayer2.autoPlay = false;
            qmlAvPlayer1.source = "";
            qmlAvPlayer1.isSubStreamOfPlayer = false;
            qmlAvPlayer2.source = "";
            qmlAvPlayer2.isSubStreamOfPlayer = false;
            activeStreamUrl = "";
            activeCameraId = "";
        }
    }
    Component.onCompleted: {
        Qt.callLater(updateTargetWatch);
        if (Qt.application.arguments.indexOf("--debug-memory") !== -1) {
            console.log("[MEM-TRACK] Created Player.qml component (index: " + index + ")");
        }
        if (visible) {
            timer.start();
        }
        updateSource();
    }

    // --- Detected-target indicator (human / vehicle / animal) ---
    // Cameras report what their motion detection saw. A frame and a label are shown for a few
    // seconds after each report. Only standalone cameras are watched for now; a camera behind a
    // recorder is reached through the recorder, which does not stream these events per camera.
    property string targetType: ""
    property string targetSource: "" // MOTION, LINE, INTRUSION, ENTER, EXIT or FACE: the kind of report behind the frame
    property bool targetWatching: false
    readonly property bool targetWanted: (typeof generalSettings !== "undefined") && generalSettings.showTargetIndicator
                                          && root.isHikvision && !root.isQuickPlayback && root.recorderIp !== ""
                                          && root.visible && !root.liveSuspended && root.source !== "" && !root.recorderOffline
                                          && root.targetSwitchedOn() && root.savedLoginFor(root.recorderIp) !== null
    // The camera this tile is looking at: for a camera behind a recorder (NVR) it is looked up from
    // the recorder, once, and remembered.
    property var targetCam: null
    property string targetCamFor: ""
    // A standalone camera is its own recorder with one or two channels (a dual-lens camera has two).
    // Anything with more channels is treated as an NVR and is not watched.
    function standaloneFor(ip) {
        if (ip === "" || typeof rootWindow === "undefined" || !rootWindow.hikvisionRecordersJson)
            return false;
        try {
            var list = JSON.parse(rootWindow.hikvisionRecordersJson);
            for (var i = 0; i < list.length; ++i) {
                if (list[i].ip === ip)
                    return !list[i].cameras || list[i].cameras.length <= 2;
            }
        } catch (e) {}
        return false;
    }
    readonly property bool isStandaloneCamera: standaloneFor(root.recorderIp)

    // A recorder with one or two channels counts as a camera (a dual-lens camera has two) and keeps its own
    // connection. A recorder with more channels can take its reports from the recorder itself, when the
    // settings say so.
    readonly property bool useRecorderEvents: !root.isStandaloneCamera
                                              && (typeof generalSettings !== "undefined")
                                              && root.eventSourceChoice() === "recorder"

    // Where this camera's reports come from: its own choice (set in the detection frame window), else the general setting.
    function eventSourceChoice() {
        if (typeof generalSettings === "undefined")
            return "camera";
        try {
            var o = JSON.parse(generalSettings.targetSourceOverrides || "{}");
            var v = o[root.recorderIp + "#" + root.channelId];
            if (v === "camera" || v === "recorder")
                return v;
        } catch (e) {}
        return generalSettings.targetSource === "recorder" ? "recorder" : "camera";
    }

    // Per-camera switch for the indicator. It is kept in its own list, not in the saved recorders,
    // because saving the recorder list makes every Hikvision tile reload its source.
    function offList() {
        if (typeof generalSettings === "undefined")
            return [];
        try {
            var l = JSON.parse(generalSettings.targetOffCameras || "[]");
            return Array.isArray(l) ? l : [];
        } catch (e) {
            return [];
        }
    }

    function targetOffFor(ip) {
        return offList().indexOf(ip) >= 0;
    }

    // True when the indicator is on for the camera this tile shows (used by the right-click menu).
    function targetEnabledHere() {
        return root.targetSwitchedOn();
    }

    // Cameras behind a recorder start OFF and are switched on one at a time with the right-click menu,
    // because each one is a separate login that the recorder's password may or may not open.
    function nvrKey() {
        return root.recorderIp + "#" + root.channelId;
    }

    function nvrOnList() {
        if (typeof generalSettings === "undefined")
            return [];
        try {
            var l = JSON.parse(generalSettings.targetNvrOnCameras || "[]");
            return Array.isArray(l) ? l : [];
        } catch (e) {
            return [];
        }
    }

    function targetSwitchedOn() {
        if (root.isStandaloneCamera)
            return !root.targetOffFor(root.recorderIp);
        return root.nvrOnList().indexOf(root.nvrKey()) >= 0;
    }

    // The address to listen to. A standalone camera is its own recorder; a camera behind a recorder
    // is looked up once from the recorder and cached.
    function resolveTargetCam() {
        if (root.useRecorderEvents) {
            // One connection to the recorder itself serves every camera behind it.
            return { ip: root.recorderIp, http: (root.savedLoginFor(root.recorderIp) || { http: 80 }).http, recorder: true };
        }
        if (root.isStandaloneCamera)
            return { ip: root.recorderIp, http: (root.savedLoginFor(root.recorderIp) || { http: 80 }).http };
        var key = root.nvrKey();
        if (root.targetCam && root.targetCamFor === key)
            return root.targetCam;
        var login = root.savedLoginFor(root.recorderIp);
        if (!login)
            return null;
        // Never waits for the recorder. When its camera list is not known yet (it was not answering) it is read in the
        // background, and updateTargetWatch runs again when it arrives (proxyChannelsReady) or on the retry timer below.
        var p = HikvisionManager.proxyCameraIfCached(root.recorderIp, root.channelId);
        if (!p || !p.ip) {
            HikvisionManager.prefetchProxyChannels(root.recorderIp, login.http, login.user, login.pass);
            return null;
        }
        if (p.ip === root.recorderIp)
            return null;
        root.targetCam = { ip: p.ip, http: 80 };
        root.targetCamFor = key;
        return root.targetCam;
    }

    // The name and address of every camera behind this tile's recorder, as JSON for the detection log.
    function channelInfoJson(login) {
        var out = {};
        try {
            var list = JSON.parse(rootWindow.hikvisionRecordersJson);
            for (var i = 0; i < list.length; ++i) {
                if ((list[i].ip || "").trim().split(":")[0] !== root.recorderIp)
                    continue;
                var cams = list[i].cameras || [];
                for (var j = 0; j < cams.length; ++j) {
                    var ch = parseInt(cams[j].channelId);
                    var nm = cams[j].customName || cams[j].name || ("Camera " + ch);
                    var proxy = HikvisionManager.proxyCameraCached(root.recorderIp, login.http, login.user, login.pass, ch);
                    out[ch] = { name: (list[i].name || root.recorderIp) + " Ch. " + ch + " " + nm,
                                ip: (proxy && proxy.ip) ? proxy.ip : "" };
                }
            }
        } catch (e) {}
        return JSON.stringify(out);
    }

    // The address this tile's camera is logged under in the detection log: the camera's own address,
    // which for a camera behind a recorder is not the recorder's.
    function detectionLogIp() {
        if (root.useRecorderEvents) {
            // Lines for a camera behind a recorder are written with the camera's own address.
            var login = root.savedLoginFor(root.recorderIp);
            var p = login ? HikvisionManager.proxyCameraCached(root.recorderIp, login.http, login.user, login.pass, root.channelId) : null;
            if (p && p.ip)
                return p.ip;
        }
        if (root.watchedIp !== "" && !root.useRecorderEvents)
            return root.watchedIp;
        var cam = root.resolveTargetCam();
        return cam ? cam.ip : root.recorderIp;
    }

    // Flip the switch for the camera this tile shows. Every tile of that camera follows, and the
    // camera's connection closes at once when it is switched off.
    function toggleTargetHere() {
        if (root.recorderIp === "" || typeof generalSettings === "undefined")
            return;
        if (root.isStandaloneCamera) {
            var l = offList().slice();
            var i = l.indexOf(root.recorderIp);
            if (i >= 0)
                l.splice(i, 1);
            else
                l.push(root.recorderIp);
            generalSettings.targetOffCameras = JSON.stringify(l);
        } else {
            var n = nvrOnList().slice();
            var k = n.indexOf(root.nvrKey());
            if (k >= 0)
                n.splice(k, 1);
            else
                n.push(root.nvrKey());
            rootWindow.setTargetNvrOnCameras(JSON.stringify(n));
        }
    }

    // Right-click > VCA > Target Boxes for the camera this tile shows (every tile of that camera follows).
    readonly property bool vcaTargetsHere: {
        if (typeof generalSettings === "undefined" || root.recorderIp === "")
            return false;
        try {
            var l = JSON.parse(generalSettings.vcaTargetsOnCameras || "[]");
            return Array.isArray(l) && l.indexOf(root.nvrKey()) >= 0;
        } catch (e) {
            return false;
        }
    }
    function toggleVcaTargetsHere() {
        if (root.recorderIp === "" || typeof generalSettings === "undefined")
            return;
        var l = [];
        try {
            l = JSON.parse(generalSettings.vcaTargetsOnCameras || "[]");
            if (!Array.isArray(l))
                l = [];
        } catch (e) {}
        var i = l.indexOf(root.nvrKey());
        if (i >= 0)
            l.splice(i, 1);
        else
            l.push(root.nvrKey());
        generalSettings.vcaTargetsOnCameras = JSON.stringify(l);
    }

    // Right-click > VCA > Show VCA Line Rules. KVision draws the lines from the same smart data as the
    // target boxes. The camera's own "draw lines into the stream" switch is not changed.
    readonly property bool vcaRulesHere: {
        if (typeof generalSettings === "undefined" || root.recorderIp === "")
            return false;
        try {
            var l = JSON.parse(generalSettings.vcaRuleLinesOnCameras || "[]");
            return Array.isArray(l) && l.indexOf(root.nvrKey()) >= 0;
        } catch (e) {
            return false;
        }
    }
    function toggleVcaRulesHere() {
        if (root.recorderIp === "" || typeof generalSettings === "undefined")
            return;
        var l = [];
        try {
            l = JSON.parse(generalSettings.vcaRuleLinesOnCameras || "[]");
            if (!Array.isArray(l))
                l = [];
        } catch (e) {}
        var i = l.indexOf(root.nvrKey());
        if (i >= 0)
            l.splice(i, 1);
        else
            l.push(root.nvrKey());
        generalSettings.vcaRuleLinesOnCameras = JSON.stringify(l);
    }

    // The login for a camera, read from the saved recorder list. A tile's own username and
    // password properties are not always filled in when this runs, and a blank password sent to a
    // camera counts as a failed login and can lock the camera.
    function savedLoginFor(ip) {
        if (ip === "" || typeof rootWindow === "undefined" || !rootWindow.hikvisionRecordersJson)
            return null;
        try {
            var list = JSON.parse(rootWindow.hikvisionRecordersJson);
            for (var i = 0; i < list.length; ++i) {
                var rip = (list[i].ip || "").trim().split(":")[0];
                if (rip === ip && list[i].username && list[i].password)
                    return { user: list[i].username, pass: list[i].password,
                             http: parseInt(list[i].httpPort) || 80 };
            }
        } catch (e) {}
        return null;
    }

    function updateTargetWatch() {
        if (root.targetWanted && !root.targetWatching) {
            var cam = root.resolveTargetCam();
            var login = root.savedLoginFor(root.recorderIp);
            if (!cam || !login)
                return;
            HikvisionEvents.watch(cam.ip, cam.http, login.user, login.pass, root.cameraNameInfo, Context.configDirPath(),
                                 root.recorderIp, root.channelId, cam.recorder === true);
            if (cam.recorder === true) {
                HikvisionEvents.setChannelInfo(cam.ip, root.channelInfoJson(login));
                root.lensChannel = 0;
            } else {
                // A camera with more than one lens reports each lens as its own channel on one stream.
                var lens = root.lensInfo(login, cam.ip);
                root.lensChannel = lens.mine;
                if (lens.count > 1)
                    HikvisionEvents.setLensInfo(cam.ip, JSON.stringify(lens.map));
            }
            root.targetWatching = true;
            root.watchedIp = cam.ip;
        } else if (!root.targetWanted && root.targetWatching) {
            console.debug("[Target] tile " + root.index + " STOPPED watching: visible=" + root.visible + " source=" + (root.source !== "")
                        + " standalone=" + root.isStandaloneCamera + " on=" + root.targetSwitchedOn()
                        + " login=" + (root.savedLoginFor(root.recorderIp) !== null) + " setting=" + generalSettings.showTargetIndicator);
            HikvisionEvents.unwatch(root.watchedIp);
            root.targetWatching = false;
            root.targetType = "";
            root.targetSource = "";
        }
    }
    property string watchedIp: ""
    onTargetWantedChanged: updateTargetWatch()

    // A camera behind a recorder is found through the recorder. If the recorder was not answering (unplugged, rebooting, just
    // switched back from Offline) the watch could not start; ask again every 20 seconds until it does. Nothing here waits for
    // the recorder, and a recorder that is set Offline is not asked at all (targetWanted is false then).
    Timer {
        id: targetRetryTimer
        interval: 20000
        repeat: true
        running: root.targetWanted && !root.targetWatching && !root.useRecorderEvents && !root.isStandaloneCamera
        onTriggered: root.updateTargetWatch()
    }
    Connections {
        target: HikvisionManager
        function onProxyChannelsReady(nvrIp, ok) {
            if (!ok || nvrIp !== root.recorderIp)
                return;
            if (root.targetWanted && !root.targetWatching)
                root.updateTargetWatch();
            else if (root.targetWatching && root.useRecorderEvents) {
                var login = root.savedLoginFor(root.recorderIp);
                if (login)
                    HikvisionEvents.setChannelInfo(root.watchedIp, root.channelInfoJson(login));
            }
            if (root.streamIndex > 2)
                root.updateSource();
        }
    }

    // A dragged camera keeps the player that was already on the tile. The detection subscription
    // belongs to that player, so it has to be pointed at the camera that just arrived. The address
    // and the channel are written one after the other; one deferred pass restarts the watch after both.
    property bool targetRetargetQueued: false

    function restartTargetWatch() {
        if (root.targetRetargetQueued)
            return;
        root.targetRetargetQueued = true;
        if (root.targetWatching) {
            var oldIp = root.watchedIp;
            root.targetWatching = false;
            root.watchedIp = "";
            root.lensChannel = 0;
            root.targetCam = null;
            root.targetCamFor = "";
            root.targetType = "";
            root.targetSource = "";
            root.trackingFlag = false;
            root.followLogged = false;
            root.siblingType = "";
            root.siblingAt = 0;
            root.returnSlew = false;
            root.ptzMovedAt = 0;
            root.parkedAt = 0;
            root.lastTargetReport = 0;
            root.lastSmartAt = 0;
            console.debug("[Target] tile " + root.index + " camera changed, stopped watching " + oldIp);
            if (oldIp !== "")
                HikvisionEvents.unwatch(oldIp);
        }
        Qt.callLater(root.applyTargetWatch);
    }

    function applyTargetWatch() {
        root.targetRetargetQueued = false;
        root.updateTargetWatch();
    }

    onUseRecorderEventsChanged: {
        // The source setting changed: close the old connection and open the one the setting now asks for.
        root.restartTargetWatch();
    }

    Connections {
        target: HikvisionEvents
        onTargetDetected: {
            if (ip === root.recorderIp || ip === root.watchedIp)
                console.debug("[Target] tile " + root.index + " got " + targetType + " for " + ip + " watching=" + root.targetWatching
                            + " watchedIp=" + root.watchedIp + " hold=" + root.targetHoldMs + " ms");
            if (root.targetWatching && ip === root.watchedIp && root.reportIsMine(channel)) {
                // A line, intrusion, entrance or exit report is what the user cares about, so for a few seconds after
                // one, a plain motion report (which is often somebody elsewhere in the picture) does not change the
                // label. The detection log keeps every report, so nothing is lost.
                if (source === "MOTION" && root.targetType !== "" && Date.now() - root.lastSmartAt <= root.smartCarryMs) {
                    root.lastTargetReport = Date.now();
                    return;
                }
                if (source !== "MOTION")
                    root.lastSmartAt = Date.now();
                root.targetSource = source;
                root.targetType = targetType;
                root.lastTargetReport = Date.now();
                HikvisionEvents.logFrame(ip, root.targetCaption(" - "), root.index, root.cameraNameInfo);
            } else if (root.targetWatching && ip === root.watchedIp && root.lensChannel > 0 && channel > 0 && channel !== root.lensChannel) {
                // The other lens of this camera saw something. A PTZ lens is told where to point by it.
                root.siblingType = targetType;
                root.siblingAt = Date.now();
                // Already off park and moving: there is no new "leave", so the position reports are the follow.
                // A report during the way home is not that. The other lens still sees the target the whole way back.
                if (!root.returnSlew && !root.trackingFlag && root.ptzMoveIsFresh() && root.ptzMovedAt > root.parkedAt)
                    root.beginFollow();
                else
                    root.showTracking();
            }
        }
    }

    // --- A PTZ lens following a target that the other lens saw ---
    // The camera says when the PTZ leaves its park preset ("leave"), where it points while it moves, and when it is
    // back. It does not name the target: that comes from the other lens (the wide view). A follow that is already
    // under way sends positions and no new "leave", so a fresh target plus a recent move is logged the same way.
    // While it follows, this tile shows that target with TRACKING, unless this lens already has its own report up.
    property bool trackingFlag: false
    property bool followLogged: false
    property double trackingAt: 0
    property double ptzMovedAt: 0
    property double parkedAt: 0
    property string siblingType: ""
    property double siblingAt: 0
    property bool returnSlew: false // positions on the way back to park, until the lens has been still
    readonly property int trackingStaleMs: 30000 // the camera stopped sending positions: it is not following any more
    readonly property int siblingFreshMs: 15000  // the other lens's report is only used this long
    readonly property int ptzMoveFreshMs: 5000   // a position report this recent means the PTZ is moving

    function siblingIsFresh() {
        return root.siblingType !== "" && Date.now() - root.siblingAt <= root.siblingFreshMs;
    }

    function ptzMoveIsFresh() {
        return root.ptzMovedAt > 0 && Date.now() - root.ptzMovedAt <= root.ptzMoveFreshMs;
    }

    function beginFollow() {
        root.trackingFlag = true;
        root.returnSlew = false;
        root.trackingAt = Date.now();
        root.showTracking();
    }

    function showTracking() {
        var now = Date.now();
        if (!root.trackingFlag || now - root.trackingAt > root.trackingStaleMs)
            return;
        if (!root.siblingIsFresh())
            return; // the PTZ moved with no target seen (someone steering it), so no frame and no log line
        // This lens has a rule of its own on screen. Leave that label, and still record the follow once.
        if (root.targetType !== "" && root.targetSource !== "TRACKING") {
            if (!root.followLogged) {
                root.followLogged = true;
                HikvisionEvents.logTracking(root.watchedIp, root.siblingType, root.lensChannel);
            }
            return;
        }
        var starting = root.targetSource !== "TRACKING";
        var changed = starting || root.targetType !== root.siblingType;
        root.targetSource = "TRACKING";
        root.targetType = root.siblingType;
        root.lastTargetReport = now;
        if (changed)
            HikvisionEvents.logFrame(root.watchedIp, root.targetCaption(" - "), root.index, root.cameraNameInfo);
        if (starting && !root.followLogged) {
            root.followLogged = true;
            HikvisionEvents.logTracking(root.watchedIp, root.siblingType, root.lensChannel); // the log line and four snapshots
        }
    }

    function endTracking() {
        root.trackingFlag = false;
        root.followLogged = false;
        root.ptzMovedAt = 0; // the slew back to park is not a new follow
        root.returnSlew = true;
        root.parkedAt = Date.now();
        if (root.targetSource === "TRACKING") {
            root.targetType = "";
            root.targetSource = "";
        }
    }

    Connections {
        target: HikvisionEvents
        onTrackingChanged: {
            if (!(root.targetWatching && ip === root.watchedIp && root.lensChannel > 0 && channel === root.lensChannel))
                return;
            if (tracking)
                root.beginFollow();
            else
                root.endTracking();
        }
        onPtzMoved: {
            if (!(root.targetWatching && ip === root.watchedIp && root.lensChannel > 0 && channel === root.lensChannel))
                return;
            var now = Date.now();
            if (root.trackingFlag) {
                root.ptzMovedAt = now;
                root.trackingAt = now;
                root.showTracking();
                return;
            }
            // One continuous slew. The way home keeps sending positions, so a new follow starts only after a pause.
            if (root.returnSlew && ((root.ptzMovedAt > 0 && now - root.ptzMovedAt <= root.ptzMoveFreshMs) ||
                                    (root.ptzMovedAt === 0 && now - root.parkedAt <= root.ptzMoveFreshMs))) {
                root.ptzMovedAt = now;
                return;
            }
            root.returnSlew = false;
            root.ptzMovedAt = now;
            if (root.siblingIsFresh() && root.siblingAt > root.parkedAt)
                root.beginFollow();
        }
    }

    Connections {
        target: HikvisionEvents
        onMotionDetected: {
            // Some cameras say what they saw only once per target (the first report), then send plain
            // motion while it moves. Plain motion never starts a frame, but it keeps one alive.
            if (root.targetWatching && ip === root.watchedIp && root.reportIsMine(channel) && root.targetType !== "")
                root.lastTargetReport = Date.now();
        }
    }

    // On a recorder connection every camera behind the recorder reports on the same stream, so a tile only takes
    // the reports that name its own channel. On a camera's own connection every report is the tile's.
    function reportIsMine(channel) {
        if (root.useRecorderEvents)
            return channel === root.channelId;
        // A camera with several lenses: a report names the lens, and a tile takes only its own.
        if (root.lensChannel > 0 && channel > 0)
            return channel === root.lensChannel;
        return true;
    }

    // The camera's own channel this tile shows, when the camera has more than one lens (0 otherwise).
    property int lensChannel: 0

    // The lenses of the camera this tile watches: its own channel numbers, with the name and the recorder channel
    // each one has. A standalone camera lists its own channels; a camera behind a recorder is found by the address
    // the recorder says several of its channels share. count is 1 for an ordinary camera.
    function lensInfo(login, camIp) {
        var out = { count: 1, mine: 0, map: {} };
        try {
            var list = JSON.parse(rootWindow.hikvisionRecordersJson);
            for (var i = 0; i < list.length; ++i) {
                var rec = list[i];
                if ((rec.ip || "").trim().split(":")[0] !== root.recorderIp)
                    continue;
                var recName = rec.name || root.recorderIp;
                var cams = rec.cameras || [];
                var n = 0;
                for (var j = 0; j < cams.length; ++j) {
                    var ch = parseInt(cams[j].channelId);
                    var nm = recName + " Ch. " + ch + " " + (cams[j].customName || cams[j].name || ("Camera " + ch));
                    var lensNo = ch;
                    if (!root.isStandaloneCamera) {
                        var p = HikvisionManager.proxyCameraCached(root.recorderIp, login.http, login.user, login.pass, ch);
                        if (!p || p.ip !== camIp)
                            continue;
                        lensNo = p.channel || 1;
                    }
                    out.map[lensNo] = { name: nm, channel: ch };
                    ++n;
                    if (ch === root.channelId)
                        out.mine = lensNo;
                }
                out.count = n;
                break;
            }
        } catch (e) {}
        if (out.count < 2)
            out.mine = 0;
        return out;
    }

    // The words on the frame: the target, then what kind of report it was, e.g. "HUMAN \u2013 LINE" or
    // "HUMAN \u2013 MOTION". A target the camera did not name reads just "MOTION", not "MOTION - MOTION".
    function targetCaption(sep) {
        if (root.targetType === "face")
            return qsTr("FACE DETECTED"); // a face report names no box and no target kind
        var base = root.targetType === "human" ? qsTr("HUMAN")
                 : (root.targetType === "vehicle" ? qsTr("VEHICLE")
                 : (root.targetType === "animal" ? qsTr("ANIMAL") : qsTr("MOTION")));
        var kind = root.targetSource;
        // A rule (line, intrusion...) that fired on a target the camera could not classify says OTHER, as the detection
        // log does, so it is not mistaken for the plain motion report.
        if (root.targetType === "other" && kind !== "" && kind !== "MOTION")
            base = qsTr("OTHER");
        if (kind === "MOTION" && base === qsTr("MOTION"))
            kind = "";
        return base + (kind !== "" ? sep + kind : "");
    }

    // The frame is hidden by comparing the clock with the time of the last report, so it does not
    // depend on one long timer interval. (A 30 s one-shot timer was seen to fire after about 19 s.)
    property double lastTargetReport: 0
    property double lastSmartAt: 0 // when the last line, intrusion, entrance or exit report arrived
    readonly property int smartCarryMs: 10000 // a smart report holds the label against plain motion this long
    readonly property int targetHoldMs: ((typeof generalSettings !== "undefined") ? generalSettings.targetHoldSeconds : 10) * 1000

    Timer {
        id: targetHideTimer
        interval: 500
        repeat: true
        running: root.targetType !== ""
        onTriggered: {
            var age = Date.now() - root.lastTargetReport;
            if (age >= root.targetHoldMs) {
                console.debug("[Target] tile " + root.index + " frame cleared after " + age + " ms (hold " + root.targetHoldMs + " ms)");
                root.targetType = "";
                root.targetSource = "";
            }
        }
    }

    // --- Hold-to-talk (two-way audio) ---
    property string talkMessage: ""
    readonly property string talkKey: root.recorderIp + "#" + root.channelId + "#" + root.index
    readonly property bool talkActiveHere: HikvisionTalk.active && HikvisionTalk.activeKey === talkKey

    // Talk goes straight to the camera. A standalone camera is its own recorder. For a camera
    // behind an NVR, the camera's address comes from the list already read in the background.
    // Hover starts that read. Until it arrives, talk uses the recorder address, and the next press uses the camera.
    property var talkTarget: null          // { ip, port, channel } once resolved
    property string talkTargetFor: ""      // which recorder/channel the cache belongs to

    function resolveTalkTarget() {
        var key = root.recorderIp + "#" + root.channelId;
        if (root.talkTarget && root.talkTargetFor === key)
            return root.talkTarget;
        var target = { ip: root.recorderIp, port: root.sdkPort || root.recorderPort || 8000, channel: 1, viaRecorder: false };
        if (root.isHikvision && root.recorderIp !== "" && root.username !== "") {
            var proxy = HikvisionManager.proxyCamera(root.recorderIp, root.httpPort || 80, root.username, root.password, root.channelId);
            if (proxy && proxy.ip && proxy.ip !== root.recorderIp)
                target = { ip: proxy.ip, port: proxy.sdkPort || 8000, channel: 1, viaRecorder: true };
            // Remember a finished answer only. An empty one means the list is still on its way, so the next press asks again.
            if ((proxy && proxy.ip) || HikvisionManager.proxyListKnown(root.recorderIp)) {
                root.talkTarget = target;
                root.talkTargetFor = key;
            }
        } else {
            root.talkTarget = target;
            root.talkTargetFor = key;
        }
        return target;
    }

    function startTalk() {
        if (!root.isHikvision || root.recorderIp === "" || root.isQuickPlayback)
            return;
        root.talkMessage = "";
        var mic = (typeof generalSettings !== "undefined") ? generalSettings.talkMicrophone : "";
        var gain = (typeof generalSettings !== "undefined") ? generalSettings.talkGain : 2.0;
        var boost = (typeof generalSettings !== "undefined") ? generalSettings.talkBoostDb : 0.0;
        var t = root.resolveTalkTarget();
        HikvisionTalk.start(root.talkKey, t.ip, t.port, root.username, root.password, mic, gain, boost);
    }

    onRecorderIpChanged: {
        talkTarget = null;
        talkTargetFor = "";
        // A tile that is not watching yet is started by Component.onCompleted. Restarting here
        // would subscribe twice on the first read of the address.
        if (root.targetWatching)
            root.restartTargetWatch();
    }
    onChannelIdChanged: {
        talkTarget = null;
        talkTargetFor = "";
        if (root.targetWatching)
            root.restartTargetWatch();
    }

    function stopTalk() {
        if (root.talkActiveHere)
            HikvisionTalk.stop();
    }

    // Camera speaker volume (stored on the camera, 0-100); -1 means not loaded yet.
    property int talkSpeakerVolume: -1
    property string talkVolumeStatus: ""
    property string talkVolumeIp: ""

    function openTalkVolume() {
        if (!root.isHikvision || root.recorderIp === "")
            return;
        root.talkSpeakerVolume = -1;
        root.talkVolumeStatus = qsTr("Reading the camera...");
        talkVolumePopup.open();
        var t = root.resolveTalkTarget();
        root.talkVolumeIp = t.ip;
        HikvisionTalk.loadSpeakerVolume(t.ip, t.viaRecorder ? 80 : (root.httpPort || 80), root.username, root.password);
    }

    Connections {
        target: HikvisionTalk
        onSpeakerVolumeLoaded: {
            if (ip !== root.talkVolumeIp || !talkVolumePopup.opened)
                return;
            if (volume >= 0) {
                root.talkSpeakerVolume = volume;
                root.talkVolumeStatus = "";
            } else {
                root.talkVolumeStatus = qsTr("Could not read the camera's speaker volume.");
            }
        }
        onSpeakerVolumeSaved: {
            if (ip !== root.talkVolumeIp || !talkVolumePopup.opened)
                return;
            root.talkVolumeStatus = ok ? qsTr("Saved on the camera.") : qsTr("Could not save to the camera.");
        }
    }

    Timer {
        id: talkVolumeSaveTimer
        interval: 600
        onTriggered: {
            var t = root.resolveTalkTarget();
            HikvisionTalk.saveSpeakerVolume(t.ip, t.viaRecorder ? 80 : (root.httpPort || 80),
                                            root.username, root.password, root.talkSpeakerVolume);
        }
    }

    Connections {
        target: HikvisionTalk
        onFinished: {
            if (key === root.talkKey)
                root.talkMessage = message;
        }
    }

    // The camera behind this tile, its own address and the channel this tile is on that camera. A standalone camera is its
    // own recorder; for a camera behind an NVR the recorder's list says (from what it has remembered: never waits for it).
    function resolveAimTarget() {
        if (!root.isHikvision || root.recorderIp === "" || root.isQuickPlayback)
            return null;
        var login = root.savedLoginFor(root.recorderIp);
        if (!login)
            return null;
        if (root.isStandaloneCamera)
            return { ip: root.recorderIp, http: login.http, channel: root.channelId, user: login.user, pass: login.pass };
        var p = HikvisionManager.proxyCameraIfCached(root.recorderIp, root.channelId);
        if (!p || !p.ip) {
            HikvisionManager.prefetchProxyChannels(root.recorderIp, login.http, login.user, login.pass);
            return null;
        }
        if (p.ip === root.recorderIp)
            return null;
        return { ip: p.ip, http: 80, channel: p.channel || 1, user: login.user, pass: login.pass };
    }

    readonly property string aimKey: root.recorderIp + "#" + root.channelId

    // Asks the camera once (the first time the pointer reaches the tile) whether this is the wide lens of a two-lens PTZ.
    // An NVR's camera list that is not known yet is read in the background and this runs again when it arrives.
    function checkAimLens() {
        var key = root.aimKey;
        if (root.aimCheckedFor === key)
            return;
        var t = root.resolveAimTarget();
        if (!t)
            return;
        root.aimCheckedFor = key;
        root.aimTarget = t;
        HikvisionPtzAim.checkWideLens(t.ip, t.http, t.user, t.pass, t.channel);
    }

    function showAimMessage(text, failed) {
        root.aimMessage = text;
        root.aimFailed = failed;
        aimMessageTimer.restart();
    }

    Connections {
        target: HikvisionPtzAim
        function onLensChecked(ip, channel, ok, wide, message) {
            if (root.aimTarget && ip === root.aimTarget.ip && channel === root.aimTarget.channel) {
                root.aimWide = ok;
                root.aimIsWide = wide;
                root.aimWideFor = root.aimKey;
            }
        }
        function onAimResult(ip, ok, message) {
            if (!root.aimSent || !root.aimTarget || ip !== root.aimTarget.ip)
                return;
            root.aimSent = false;
            root.showAimMessage(ok ? qsTr("Camera is turning to the box...") : qsTr("Could not point the camera: %1").arg(message), !ok);
        }
    }

    Connections {
        target: HikvisionManager
        function onProxyChannelsReady(nvrIp, ok) {
            if (ok && nvrIp === root.recorderIp && playerHoverArea.isHovered)
                root.checkAimLens();
        }
    }

    Timer {
        id: aimMessageTimer
        interval: 6000
        onTriggered: root.aimMessage = ""
    }

    Timer {
        id: talkMessageTimer
        interval: 6000
        running: root.talkMessage !== ""
        onTriggered: root.talkMessage = ""
    }

    function showSnapshotDialog(path) {
        localSnapshotSavedDialog.filePath = path;
        localSnapshotSavedDialog.open();
    }

    function takeSnapshot(forceHD) {
        var typeStr = root.isQuickPlayback ? "QUICK_PLAYBACK" : "LIVE";
        captureCurrentFrameAndNotify(typeStr, false);
    }

    // Time used to name snapshots. It always comes from the camera/NVR clock,
    // never from the PC, whenever the source provides one:
    //  - playback: the timestamp of the frame being displayed (SDK decoder),
    //    falling back to the NVR timeline position of the player
    //  - live Hikvision: the recorder's own clock
    // Plain RTSP/HTTP sources expose no camera clock, so the PC clock is the only option.
    function cameraSnapshotTime() {
        if (root.isQuickPlayback) {
            var item = quickPlaybackPlayerLoader.item;
            if (item && item.currentFrameTimeMs) {
                var frameMs = item.currentFrameTimeMs();
                if (frameMs > 0)
                    return new Date(frameMs);
            }
            if (root.quickPlaybackActivationTime)
                return new Date(root.quickPlaybackActivationTime.getTime() - (1800 - root.quickPlaybackOffset) * 1000);
        } else if (root.isHikvision && root.recorderIp !== "" && typeof HikvisionManager !== "undefined") {
            var devMs = HikvisionManager.cachedDeviceTimeMs(root.recorderIp);
            HikvisionManager.refreshDeviceTime(root.recorderIp, root.recorderPort || 8000, root.username, root.password, true);
            if (devMs > 0)
                return new Date(devMs);
            console.log("Snapshot: recorder clock unavailable for", root.recorderIp);
        } else {
            console.log("Snapshot: source has no camera clock, using PC time for the file name");
        }
        return new Date();
    }

    function captureCurrentFrameAndNotify(typeStr, zoomedOnly) {
        var stamp = root.cameraSnapshotTime();
        var activeOutput = null;
        var nativeWidth = 1920;
        var nativeHeight = 1080;

        var recorderLabel = "";
        var cameraLabel = "Camera";
        if (root.isHikvision && root.recorderIp) {
            try {
                var jsonStr = rootWindow.hikvisionRecordersJson;
                var recordersList = jsonStr ? JSON.parse(jsonStr) : [];
                for (var i = 0; i < recordersList.length; ++i) {
                    if (recordersList[i].ip === root.recorderIp) {
                        recorderLabel = recordersList[i].name || "";
                        if (recordersList[i].cameras) {
                            for (var j = 0; j < recordersList[i].cameras.length; ++j) {
                                if (parseInt(recordersList[i].cameras[j].channelId) === root.channelId) {
                                    cameraLabel = recordersList[i].cameras[j].customName || recordersList[i].cameras[j].name || cameraLabel;
                                    break;
                                }
                            }
                        }
                        break;
                    }
                }
            } catch (e) {
                console.log("Error looking up snapshot names:", e);
            }
        } else {
            cameraLabel = root.cameraNameInfo || cameraLabel;
        }

        var path = Utils.snapshotSavePath(recorderLabel, root.channelId, cameraLabel, stamp);
        if (zoomedOnly) {
            path = path.replace(/(\.[^.\/]+)$/, "_zoomed$1");
        }

        snapshotBadge.isSavingSnapshot = true;
        snapshotBadgeTimer.restart();

        if (root.isQuickPlayback && quickPlaybackPlayerLoader.item) {
            if (zoomedOnly) {
                // Save the zoomed view exactly as it is shown on screen. Scale the grab up
                // so the visible part keeps roughly the source resolution (capped at 4x).
                var fr = root.fittedVideoRect();
                var src = root.videoFrameSize();
                var gain = Math.max(1, Math.min(4, (src.width * root.zoomWidth) / Math.max(1, fr.width)));
                var grabSize = Qt.size(Math.round(videoContainer.width * gain), Math.round(videoContainer.height * gain));
                videoContainer.grabToImage(function(result) {
                    if (result.saveToFile(path)) {
                        console.log("Saved zoomed snapshot (" + typeStr + ") to", path);
                        showSnapshotDialog(path);
                    } else {
                        console.log("Failed to save zoomed snapshot (" + typeStr + ")");
                    }
                }, grabSize);
                return;
            }
            var saved = quickPlaybackPlayerLoader.item.saveCurrentFrame(path);
            if (saved) {
                console.log("Saved snapshot (" + typeStr + ") to", path);
                showSnapshotDialog(path);
            } else {
                console.log("Failed to save snapshot (" + typeStr + ") via C++ saveCurrentFrame");
            }
            return;
        }

        if (root.isHikvision && !hikPlayerSettings.useRealStreams) {
            activeOutput = hikPlayer;
        } else if (activePlayerIndex === 1) {
            activeOutput = videoOutput1;
            nativeWidth = videoOutput1.sourceRect.width > 0 ? videoOutput1.sourceRect.width : 1920;
            nativeHeight = videoOutput1.sourceRect.height > 0 ? videoOutput1.sourceRect.height : 1080;
        } else {
            activeOutput = videoOutput2;
            nativeWidth = videoOutput2.sourceRect.width > 0 ? videoOutput2.sourceRect.width : 1920;
            nativeHeight = videoOutput2.sourceRect.height > 0 ? videoOutput2.sourceRect.height : 1080;
        }

        activeOutput.grabToImage(function(result) {
            result.saveToFile(path);
            console.log("Saved snapshot (" + typeStr + ") to", path);
            showSnapshotDialog(path);
        }, Qt.size(nativeWidth, nativeHeight));
    }

    function prepareForSwap() {
        stallBackoffMs = 0;
        stallLastAttemptMs = 0;
        seamlessSwitchTimer.stop();
        qmlAvPlayer1.stop();
        qmlAvPlayer2.stop();
        qmlAvPlayer1.source = "";
        qmlAvPlayer1.isSubStreamOfPlayer = false;
        qmlAvPlayer2.source = "";
        qmlAvPlayer2.isSubStreamOfPlayer = false;
        activeStreamUrl = "";
        activeCameraId = "";
    }

    // Opens the camera's own web interface in the default browser. For a camera
    // behind an NVR the camera's real IP comes from the list already read in the background.
    // If that list is still on its way, the browser opens when it arrives. A standalone camera,
    // or a lookup that finds nothing, uses the recorder address.
    property bool webUiWaiting: false
    function openCameraWebUi() {
        if (!isHikvision || recorderIp === "") return;
        function openHost(host, port) {
            WebBrowser.open("http://" + host + (port === 80 ? "" : ":" + port));
        }
        var proxy = HikvisionManager.proxyCamera(recorderIp, httpPort || 80, username, password, channelId);
        if (proxy && proxy.ip && proxy.ip !== recorderIp) {
            openHost(proxy.ip, 80);
            return;
        }
        if (HikvisionManager.proxyListKnown(recorderIp) || !HikvisionManager.proxyFetchPending(recorderIp)) {
            openHost(recorderIp, httpPort || 80);
            return;
        }
        if (root.webUiWaiting)
            return;
        root.webUiWaiting = true;
        var ip = recorderIp;
        var ch = channelId;
        var fallbackPort = httpPort || 80;
        function onReady(nvrIp, ok) {
            if ((nvrIp || "").split(":")[0] !== (ip || "").split(":")[0])
                return;
            HikvisionManager.proxyChannelsReady.disconnect(onReady);
            root.webUiWaiting = false;
            var p = ok ? HikvisionManager.proxyCameraIfCached(ip, ch) : null;
            if (p && p.ip && p.ip !== (ip || "").split(":")[0])
                openHost(p.ip, 80);
            else
                openHost(ip, fallbackPort);
        }
        HikvisionManager.proxyChannelsReady.connect(onReady);
    }

    function openPlayback() {
        var recInfo = {
            "ip": root.recorderIp,
            "port": root.sdkPort || root.recorderPort || 8000,
            "sdkPort": root.sdkPort || root.recorderPort || 8000,
            "httpPort": root.httpPort || 80,
            "rtspPort": root.rtspPort || 554,
            "username": root.username,
            "password": root.password
        };
        var camName = root.cameraNameInfo || ("Camera " + root.channelId);

        if (typeof rootWindow !== "undefined" && rootWindow) {
            rootWindow.openPlaybackWindow(recInfo, root.channelId, camName);
        }
    }

    Component.onDestruction: {
        if (root.targetWatching) HikvisionEvents.unwatch(root.watchedIp);
        if (Qt.application.arguments.indexOf("--debug-memory") !== -1) {
            console.log("[MEM-TRACK] Destroyed Player.qml component (index: " + index + ")");
        }
        timer.stop();
        qmlAvPlayer1.autoPlay = false;
        qmlAvPlayer2.autoPlay = false;
        qmlAvPlayer1.source = "";
        qmlAvPlayer1.isSubStreamOfPlayer = false;
        qmlAvPlayer2.source = "";
        qmlAvPlayer2.isSubStreamOfPlayer = false;
        activeStreamUrl = "";
        activeCameraId = "";
    }

    signal mediaError(string errorSource)

    Timer {
        id: timer

        interval: 50

        onTriggered: {
            if (root.visible && !root.liveSuspended) {
                qmlAvPlayer1.autoPlay = true;
                qmlAvPlayer2.autoPlay = true;
            }
        }
    }

    Rectangle {
        color: root.color
        border.color: "#101010"
        anchors.fill: parent


        Item {
            id: videoContainer
            anchors.fill: parent
            clip: true

            // VideoOutput handles either regular RTSP or Hikvision RTSP Fallback
            VideoOutput {
                id: videoOutput1
                source: qmlAvPlayer1
                x: root.isOneToOne ? root.oneToOneX : root.fittedVideoRect().x - root.zoomX * (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                y: root.isOneToOne ? root.oneToOneY : root.fittedVideoRect().y - root.zoomY * (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                width: root.isOneToOne ? (sourceRect.width > 0 ? sourceRect.width : parent.width) : (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                height: root.isOneToOne ? (sourceRect.height > 0 ? sourceRect.height : parent.height) : (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                fillMode: VideoOutput.Stretch
                visible: (!root.isHikvision || hikPlayerSettings.useRealStreams)
                opacity: activePlayerIndex === 1 ? 1.0 : 0.0
                z: activePlayerIndex === 1 ? 2 : 1

                onSourceRectChanged: {
                    if (root.isOneToOne && root.activePlayerIndex === 1) {
                        root.oneToOneX = Math.min(0, (videoContainer.width - sourceRect.width) / 2);
                        root.oneToOneY = Math.min(0, (videoContainer.height - sourceRect.height) / 2);
                    }
                    if (root.activePlayerIndex !== 1 && sourceRect.width > 0) {
                        checkSeamlessSwitch(1);
                    }
                }
            }

            VideoOutput {
                id: videoOutput2
                source: qmlAvPlayer2
                x: root.isOneToOne ? root.oneToOneX : root.fittedVideoRect().x - root.zoomX * (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                y: root.isOneToOne ? root.oneToOneY : root.fittedVideoRect().y - root.zoomY * (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                width: root.isOneToOne ? (sourceRect.width > 0 ? sourceRect.width : parent.width) : (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                height: root.isOneToOne ? (sourceRect.height > 0 ? sourceRect.height : parent.height) : (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                fillMode: VideoOutput.Stretch
                visible: (!root.isHikvision || hikPlayerSettings.useRealStreams)
                opacity: activePlayerIndex === 2 ? 1.0 : 0.0
                z: activePlayerIndex === 2 ? 2 : 1

                onSourceRectChanged: {
                    if (root.isOneToOne && root.activePlayerIndex === 2) {
                        root.oneToOneX = Math.min(0, (videoContainer.width - sourceRect.width) / 2);
                        root.oneToOneY = Math.min(0, (videoContainer.height - sourceRect.height) / 2);
                    }
                    if (root.activePlayerIndex !== 2 && sourceRect.width > 0) {
                        checkSeamlessSwitch(2);
                    }
                }
            }

            // Hikvision C++ Painted Player renders high-tech mock layout if fallback is disabled
            HikvisionPlayer {
                id: hikPlayer
                visible: root.isHikvision && !hikPlayerSettings.useRealStreams && root.visible && !root.isQuickPlayback
                x: -root.zoomX * width
                y: -root.zoomY * height
                width: parent.width / Math.max(0.001, root.zoomWidth)
                height: parent.height / Math.max(0.001, root.zoomHeight)
                recorderIp: (root.visible && root.isHikvision && !hikPlayerSettings.useRealStreams && !root.isQuickPlayback) ? root.recorderIp : ""
                recorderPort: root.recorderPort
                username: root.username
                password: root.password
                channelId: root.channelId
                streamType: root.streamIndex === 3 ? 2 : (root.streamIndex === 2 ? 1 : 0)
            }

            Component {
                id: quickPlaybackPlayerComponent
                HikvisionArchivePlayer {
                    recorderIp: root.recorderIp
                    username: root.username
                    password: root.password
                    channelId: root.channelId
                    port: root.recorderPort
                    showVcaOverlay: (typeof generalSettings === "undefined") || generalSettings.showPlaybackVcaOverlay
                    muted: root.muted
                    volume: root.volume
                    playerStatusMessage: qsTr("LNG_00159")

                    onVideoSizeChanged: {
                        if (root.isOneToOne && root.isQuickPlayback) {
                            root.oneToOneX = Math.min(0, (videoContainer.width - videoWidth) / 2);
                            root.oneToOneY = Math.min(0, (videoContainer.height - videoHeight) / 2);
                        }
                    }
                }
            }

            Loader {
                id: quickPlaybackPlayerLoader
                z: 3
                active: root.isQuickPlayback
                visible: root.isQuickPlayback
                x: root.isOneToOne ? root.oneToOneX : root.fittedVideoRect().x - root.zoomX * (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                y: root.isOneToOne ? root.oneToOneY : root.fittedVideoRect().y - root.zoomY * (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                width: root.isOneToOne ? ((item && item.videoWidth > 0) ? item.videoWidth : root.fittedVideoRect().width) : (root.fittedVideoRect().width / Math.max(0.001, root.zoomWidth))
                height: root.isOneToOne ? ((item && item.videoHeight > 0) ? item.videoHeight : root.fittedVideoRect().height) : (root.fittedVideoRect().height / Math.max(0.001, root.zoomHeight))
                sourceComponent: quickPlaybackPlayerComponent

                onLoaded: {
                    var playStart = new Date(root.quickPlaybackActivationTime.getTime() - (1800 - root.quickPlaybackOffset) * 1000);
                    item.playAtTime(playStart);
                }
            }
        }

        Rectangle {
            id: freezeOverlay
            anchors.fill: parent
            color: "#99000000"
            visible: messageContainer.visible
            z: 2
        }

        Rectangle {
            id: messageContainer
            
            property int activeStatus: activePlayerIndex === 1 ? qmlAvPlayer1.status : qmlAvPlayer2.status
            property bool activeFramePresented: activePlayerIndex === 1 ? qmlAvPlayer1.framePresented : qmlAvPlayer2.framePresented
            property bool activeHasVideo: activePlayerIndex === 1 ? qmlAvPlayer1.hasVideo : qmlAvPlayer2.hasVideo
            // No picture yet is normal while a stream is opening. The red sign is a failed open or a stream that ended.
            property bool isError: activeStatus === MediaPlayer.InvalidMedia || activeStatus === MediaPlayer.EndOfMedia
            // Buffered is not a picture. The decoder holds mid-GOP frames until a keyframe, and the badge stays up for that wait.
            property bool pictureReady: activeFramePresented && (activeStatus === MediaPlayer.Buffered || activeStatus === MediaPlayer.LoadedMedia || (root.streamIndex === 3 && activeHasVideo))
            property string themeColor: isError ? "#e74c3c" : "#00f5d4"
            property string themeIcon: isError ? "\u26A0" : "\u21BB"
            property string statusText: {
                if (!isError && !activeFramePresented)
                    return qsTr("LNG_00199");
                var progress = activePlayerIndex === 1 ? qmlAvPlayer1.bufferProgress : qmlAvPlayer2.bufferProgress;
                switch (activeStatus) {
                case MediaPlayer.NoMedia:
                case MediaPlayer.Loading:
                    return qsTr("LNG_00199");
                case MediaPlayer.Loaded:
                    return qsTr("LNG_00198");
                case MediaPlayer.Stalled:
                    return qsTr("LNG_00197");
                case MediaPlayer.Buffering:
                    return qsTr("LNG_00196").arg(Math.round(progress * 100));
                case MediaPlayer.EndOfMedia:
                case MediaPlayer.InvalidMedia:
                    return qsTr("LNG_00195");
                default:
                    return "";
                }
            }
            
            anchors.centerIn: parent
            width: messageRow.width + 30
            height: messageRow.height + 20
            color: "#cc000000"
            border.color: themeColor
            border.width: 1
            radius: 8
            visible: root.activeStreamUrl !== "" && !root.isQuickPlayback && (!root.isHikvision || hikPlayerSettings.useRealStreams) && !pictureReady
            z: 3

            Row {
                id: messageRow
                anchors.centerIn: parent
                spacing: 8
                Text {
                    text: messageContainer.themeIcon
                    color: messageContainer.themeColor
                    font.pixelSize: 18
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    id: message
                    text: messageContainer.statusText
                    color: messageContainer.themeColor
                    font.bold: true
                    font.pixelSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // Live smart overlay (right-click > VCA): rule lines and target boxes, read from the camera's smart
        // data over a light SDK sub-stream connection and drawn over the live picture, as iVMS-4200 does.
        // It connects only while one of the two is switched on and the tile shows live video. The camera is not changed.
        HikvisionVcaOverlay {
            id: liveVcaOverlay
            z: 8
            anchors.fill: parent
            readonly property var login: root.savedLoginFor(root.recorderIp)
            showRules: root.vcaRulesHere
            showTargets: root.vcaTargetsHere
            active: (root.vcaTargetsHere || root.vcaRulesHere) && root.isHikvision && !root.isQuickPlayback
                    && root.visible && !root.liveSuspended && root.source !== "" && login !== null
                    && !root.isOneToOne && !root.isZoomed
            recorderIp: root.recorderIp
            port: root.sdkPort || root.recorderPort || 8000
            username: login ? login.user : ""
            password: login ? login.pass : ""
            channelId: root.channelId
            videoRect: root.fittedVideoRect()
            // Says why the boxes are not shown (in the log), when they are switched on for this tile.
            readonly property string whyNot: !(root.vcaTargetsHere || root.vcaRulesHere) ? "" :
                (!root.isHikvision ? "not a Hikvision tile" : root.isQuickPlayback ? "quick playback" :
                 !root.visible ? "tile hidden" : root.liveSuspended ? "playback window open" :
                 root.source === "" ? "no source" : login === null ? "no saved login for " + root.recorderIp :
                 root.isOneToOne ? "1:1 view" : root.isZoomed ? "zoomed" : "")
            onWhyNotChanged: if (whyNot !== "") console.info("[VcaLive] " + root.recorderIp + " smart overlay waiting: " + whyNot)
            onActiveChanged: console.info("[VcaLive] " + root.recorderIp + " ch " + root.channelId + " smart overlay " + (active ? "active" : "inactive"))
        }

        Rectangle {
            id: targetFrame
            z: 9
            anchors.fill: parent
            color: "transparent"
            radius: 2
            // The frame and its label shrink with the tile's height: full size (1.0) from a tile 650 pixels high
            // upward, 0.83 at 430 (a merged cell that is an eighth of the screen), and 0.55 or less on small
            // tiles (still readable). They never grow beyond full size.
            readonly property real labelScale: Math.max(0.55, Math.min(1.0, 0.4977 + height * 0.000773))
            border.width: Math.max(2, Math.round(4 * labelScale))
            border.color: root.targetSource === "TRACKING" ? "#ffb703" : (root.targetType === "face" ? "#b45cff" : root.targetType === "human" ? "#ff5a36" : (root.targetType === "vehicle" ? "#2d8cff" : "#2ecc71"))
            visible: root.targetType !== ""
            opacity: visible ? 1.0 : 0.0

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Math.round(6 * targetFrame.labelScale)
                height: targetLabel.implicitHeight + Math.round(8 * targetFrame.labelScale)
                width: targetLabel.implicitWidth + Math.round(16 * targetFrame.labelScale)
                radius: Math.max(2, Math.round(4 * targetFrame.labelScale))
                color: parent.border.color

                Text {
                    id: targetLabel
                    anchors.centerIn: parent
                    color: "#ffffff"
                    font.pixelSize: Math.max(8, Math.round(12 * targetFrame.labelScale))
                    font.bold: true
                    text: root.targetCaption(" \u2013 ")
                }
            }

        }

        Rectangle {
            id: talkBanner
            z: 12
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 10
            width: talkBannerRow.width + 24
            height: talkBannerRow.height + 12
            radius: 6
            color: "#dd000000"
            border.width: 1
            border.color: root.talkMessage !== "" ? "#e74c3c" : (HikvisionTalk.live ? "#e74c3c" : "#ff7a00")
            visible: root.talkActiveHere || root.talkMessage !== ""

            Row {
                id: talkBannerRow
                anchors.centerIn: parent
                spacing: 8

                Text {
                    id: talkBannerText
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: 12
                    font.bold: true
                    color: root.talkMessage !== "" ? "#ff6b5b" : "#ffffff"
                    text: root.talkMessage !== "" ? root.talkMessage
                          : (HikvisionTalk.live ? qsTr("Talking...") : qsTr("Connecting..."))
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                    height: 6
                    radius: 3
                    color: "#33ffffff"
                    visible: root.talkActiveHere && HikvisionTalk.live

                    Rectangle {
                        height: parent.height
                        radius: 3
                        width: parent.width * Math.min(1, HikvisionTalk.level)
                        color: HikvisionTalk.level > 0.85 ? "#e74c3c" : "#2ecc71"
                    }
                }
            }
        }

        Rectangle {
            id: restoringLiveOverlay
            anchors.fill: parent
            z: 10
            color: "black"
            visible: root.isRestoringLiveView && !root.isQuickPlayback

            Rectangle {
                anchors.centerIn: parent
                width: restoringRow.width + 30
                height: restoringRow.height + 20
                color: "#cc000000"
                border.color: "#00f5d4"
                border.width: 1
                radius: 8

                Row {
                    id: restoringRow
                    anchors.centerIn: parent
                    spacing: 8
                    Text {
                        text: "\u21BB" // Refresh/Loading icon
                        color: "#00f5d4"
                        font.pixelSize: 18
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: qsTr("LNG_00194")
                        color: "#00f5d4"
                        font.bold: true
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        QmlAVPlayer {
            id: qmlAvPlayer1

            autoLoad: false
            property bool isSubStreamOfPlayer: false

            avOptions: {
                var avOpts = {};
                if (!root.ignoreGlobalAVFormatOptions) {
                    Object.assignDefault(avOpts, layoutsCollectionSettings.toJSValue("defaultAVFormatOptions"));
                }
                if (root.avOptions) {
                    for (var k in root.avOptions) {
                        avOpts[k] = root.avOptions[k];
                    }
                }
                if (typeof generalSettings !== "undefined" && generalSettings.disableAudio) {
                    avOpts["allowed_media_types"] = "video";
                }
                if (root.rtspTransport === "tcp" || root.rtspTransport === "udp") {
                    avOpts["rtsp_transport"] = root.rtspTransport;
                }
                if (root.aacRepairLive)
                    avOpts["rtsp_transport"] = "tcp";
                return avOpts;
            }

            onStatusChanged: {
                handlePlayerStatus(1, status);
                updateMessageText();
            }

            onHasVideoChanged: {
                checkSeamlessSwitch(1);
            }

            onHasAudioChanged: {
                checkSeamlessSwitch(1);
            }

            onFramePresentedChanged: {
                if (framePresented) {
                    checkSeamlessSwitch(1);
                }
            }

            onBufferProgressChanged: {
                updateMessageText();
            }
        }

        QmlAVPlayer {
            id: qmlAvPlayer2

            autoLoad: false
            property bool isSubStreamOfPlayer: false

            avOptions: {
                var avOpts2 = {};
                if (!root.ignoreGlobalAVFormatOptions) {
                    Object.assignDefault(avOpts2, layoutsCollectionSettings.toJSValue("defaultAVFormatOptions"));
                }
                if (root.avOptions) {
                    for (var k2 in root.avOptions) {
                        avOpts2[k2] = root.avOptions[k2];
                    }
                }
                if (typeof generalSettings !== "undefined" && generalSettings.disableAudio) {
                    avOpts2["allowed_media_types"] = "video";
                }
                if (root.rtspTransport === "tcp" || root.rtspTransport === "udp") {
                    avOpts2["rtsp_transport"] = root.rtspTransport;
                }
                if (root.aacRepairLive)
                    avOpts2["rtsp_transport"] = "tcp";
                return avOpts2;
            }

            onStatusChanged: {
                handlePlayerStatus(2, status);
                updateMessageText();
            }

            onHasVideoChanged: {
                checkSeamlessSwitch(2);
            }

            onHasAudioChanged: {
                checkSeamlessSwitch(2);
            }

            onFramePresentedChanged: {
                if (framePresented) {
                    checkSeamlessSwitch(2);
                }
            }

            onBufferProgressChanged: {
                updateMessageText();
            }
        }

        Timer {
            id: bitrateTimer
            interval: 1000
            running: (!root.isHikvision || hikPlayerSettings.useRealStreams) && root.visible && (playbackState === MediaPlayer.PlayingState)
            repeat: true
            
            property var lastBytes: 0
            property string bitrateText: "0 kbps"

            onTriggered: {
                var activePlayer = activePlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
                var currentBytes = activePlayer.bytesRead();
                var diffBytes = currentBytes - lastBytes;
                if (diffBytes < 0) {
                    diffBytes = currentBytes; // handle player restart / reset
                }
                lastBytes = currentBytes;
                
                var bps = diffBytes * 8;
                if (bps >= 1000000) {
                    bitrateText = (bps / 1000000).toFixed(2) + " Mbps";
                } else if (bps >= 1000) {
                    bitrateText = Math.round(bps / 1000) + " kbps";
                } else {
                    bitrateText = bps + " bps";
                }
            }
            
            onRunningChanged: {
                if (!running) {
                    bitrateText = "0 kbps";
                    lastBytes = 0;
                }
            }
        }

        Rectangle {
            id: streamInfoBadge
            
            anchors {
                left: parent.left
                top: parent.top
                margins: 6
            }
            
            visible: !(typeof rootWindow !== "undefined" && rootWindow.infoBadgesIdleHidden) && (!viewSettings.showInfoOnHoverOnly || playerHoverArea.containsMouse) && viewSettings.showChannelStatus && (root.isQuickPlayback ? true : ((root.source !== "") && (root.isHikvision ? (root.recorderIp !== "") : (playbackState === MediaPlayer.PlayingState || status === MediaPlayer.Buffered || status === MediaPlayer.Buffering || status === MediaPlayer.Loading))))
            
            color: "#66121214"
            border {
                color: root.isQuickPlayback ? "#00f5d4" : (root.activeIsSubStream ? "#ff7a00" : "#00f5d4")
                width: 1
            }
            radius: 4
            
            implicitWidth: contentLayout.width + 8
            implicitHeight: contentLayout.height + 4
            
            Row {
                id: contentLayout
                anchors.centerIn: parent
                spacing: 4
                
                Text {
                    text: {
                        var quality = root.isQuickPlayback ? "MAIN" : (root.streamIndex === 3 ? "THIRD" : (root.streamIndex === 2 ? "SUB" : "MAIN"));
                        var protocol = "RTSP";
                        if (root.isHikvision && typeof hikPlayerSettings !== "undefined" && !hikPlayerSettings.useRealStreams) {
                            protocol = "HikSDK";
                        } else if (!root.isHikvision && root.source.toString().indexOf("http") === 0) {
                            protocol = "HTTP";
                        }
                        // The encoding (H.265, H.264...) once the stream is open. Only a stream played by KVision's own player
                        // reports it; a tile on the Hikvision SDK player, or a quick playback, shows nothing here.
                        var codec = "";
                        if (!root.isQuickPlayback && (!root.isHikvision || hikPlayerSettings.useRealStreams))
                            codec = root.activePlayerIndex === 1 ? qmlAvPlayer1.videoCodec : qmlAvPlayer2.videoCodec;
                        return quality + " | " + protocol + (codec !== "" ? " | " + codec : "");
                    }
                    color: root.activeIsSubStream && !root.isQuickPlayback ? "#ff7a00" : "#00f5d4"
                    font {
                        pixelSize: 8
                        bold: true
                    }
                }
                
                Rectangle {
                    width: 1
                    height: 7
                    color: root.activeIsSubStream && !root.isQuickPlayback ? "#44ff7a00" : "#4400f5d4"
                    anchors.verticalCenter: parent.verticalCenter
                }
                
                Text {
                    visible: root.isQuickPlayback
                    text: root.quickPlaybackSpeed + "x"
                    color: "#ff7a00"
                    font {
                        pixelSize: 8
                        bold: true
                    }
                }

                Rectangle {
                    visible: root.isQuickPlayback
                    width: 1
                    height: 7
                    color: "#44ff7a00"
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: {
                        var fpsVal = 0;
                        if (root.isQuickPlayback && quickPlaybackPlayerLoader.item) {
                            fpsVal = quickPlaybackPlayerLoader.item.fps;
                        } else if (root.isHikvision) {
                            if (hikPlayerSettings.useRealStreams) {
                                fpsVal = (root.activePlayerIndex === 1 ? qmlAvPlayer1.fps : qmlAvPlayer2.fps);
                            } else {
                                fpsVal = hikPlayer.fps;
                            }
                        } else {
                            fpsVal = (root.activePlayerIndex === 1 ? qmlAvPlayer1.fps : qmlAvPlayer2.fps);
                        }
                        return fpsVal + " FPS";
                    }
                    color: "#eeeeee"
                    font {
                        pixelSize: 8
                        bold: true
                    }
                }
                
                Rectangle {
                    width: 1
                    height: 7
                    color: root.activeIsSubStream && !root.isQuickPlayback ? "#44ff7a00" : "#4400f5d4"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.isQuickPlayback ? false : (!root.isHikvision || hikPlayerSettings.useRealStreams)
                }
                
                Text {
                    text: bitrateTimer.bitrateText
                    color: "#eeeeee"
                    font {
                        pixelSize: 8
                    }
                    visible: root.isQuickPlayback ? false : (!root.isHikvision || hikPlayerSettings.useRealStreams)
                }
            }
        }



        Rectangle {
            id: resolutionBadge

            readonly property size frameSize: {
                // Re-evaluate when the active output reports a new size
                var w = 0, h = 0;
                if (root.isQuickPlayback && quickPlaybackPlayerLoader.item) {
                    w = quickPlaybackPlayerLoader.item.videoWidth;
                    h = quickPlaybackPlayerLoader.item.videoHeight;
                } else {
                    var out = root.activePlayerIndex === 1 ? videoOutput1 : videoOutput2;
                    w = out.sourceRect.width;
                    h = out.sourceRect.height;
                }
                return Qt.size(w, h);
            }

            anchors {
                left: parent.left
                top: streamInfoBadge.visible ? streamInfoBadge.bottom : parent.top
                topMargin: streamInfoBadge.visible ? 4 : 6
                leftMargin: 6
            }

            visible: !(typeof rootWindow !== "undefined" && rootWindow.infoBadgesIdleHidden) && (!viewSettings.showInfoOnHoverOnly || playerHoverArea.containsMouse) && viewSettings.showChannelResolution && frameSize.width > 0 && frameSize.height > 0 && (root.isQuickPlayback ? true : ((root.source !== "") && (root.isHikvision ? (root.recorderIp !== "") : true)))

            color: "#66121214"
            border {
                color: root.isQuickPlayback ? "#00f5d4" : (root.activeIsSubStream ? "#ff7a00" : "#00f5d4")
                width: 1
            }
            radius: 4

            implicitWidth: resolutionText.implicitWidth + 8
            implicitHeight: resolutionText.implicitHeight + 4

            Text {
                id: resolutionText
                anchors.centerIn: parent
                text: Math.round(resolutionBadge.frameSize.width) + "x" + Math.round(resolutionBadge.frameSize.height)
                color: "#eeeeee"
                font {
                    pixelSize: 8
                    bold: true
                }
            }
        }

        Rectangle {
            id: cameraInfoBadge
            
            anchors {
                left: parent.left
                bottom: parent.bottom
                leftMargin: 6
                bottomMargin: root.isQuickPlayback ? (quickPlaybackControlsPanel.height + 12) : 6
            }
            
            visible: !(typeof rootWindow !== "undefined" && rootWindow.infoBadgesIdleHidden) && (!viewSettings.showInfoOnHoverOnly || playerHoverArea.containsMouse) && viewSettings.showCameraInfo && root.isHikvision && root.cameraNameInfo !== ""
            
            color: "#66121214"
            border {
                color: "#ff7a00"
                width: 1
            }
            radius: 4
            
            implicitWidth: cameraInfoText.implicitWidth + 8
            implicitHeight: cameraInfoText.implicitHeight + 4
            
            Text {
                id: cameraInfoText
                anchors.centerIn: parent
                text: root.cameraNameInfo
                color: "#eeeeee"
                font {
                    pixelSize: 8
                    bold: true
                }
            }
        }

        // MouseArea to handle mouse click-and-drag for ROI Zoom selection
        MouseArea {
            id: zoomMouseArea
            anchors.fill: parent
            enabled: root.isZoomSelectionMode || (root.isZoomed && root.tightenOnDrag)
            hoverEnabled: true
            cursorShape: Qt.CrossCursor
            // The double-click that leaves a maximized camera is on the viewport behind this area.
            propagateComposedEvents: true
            onDoubleClicked: {
                isDragging = false;
                mouse.accepted = false;
            }

            property real startX: 0
            property real startY: 0
            property real currentX: 0
            property real currentY: 0
            property bool isDragging: false

            onPressed: {
                startX = mouse.x;
                startY = mouse.y;
                currentX = mouse.x;
                currentY = mouse.y;
                isDragging = true;
            }

            onPositionChanged: {
                if (isDragging) {
                    var mx = Math.max(0, Math.min(mouse.x, parent.width));
                    var my = Math.max(0, Math.min(mouse.y, parent.height));

                    if (mouse.modifiers & Qt.ShiftModifier && parent.height > 0) {
                        var dx = mx - startX;
                        var dy = my - startY;
                        var w = Math.abs(dx);
                        var h = Math.abs(dy);
                        var ratio = parent.width / parent.height;

                        if (h > 0) {
                            if (w / ratio > h) {
                                h = w / ratio;
                            } else {
                                w = h * ratio;
                            }

                            var targetX = startX + (dx >= 0 ? w : -w);
                            var targetY = startY + (dy >= 0 ? h : -h);

                            if (targetX < 0 || targetX > parent.width || targetY < 0 || targetY > parent.height) {
                                var maxW = dx >= 0 ? parent.width - startX : startX;
                                var maxH = dy >= 0 ? parent.height - startY : startY;

                                var scaleX = w > 0 ? maxW / w : 1.0;
                                var scaleY = h > 0 ? maxH / h : 1.0;
                                var scale = Math.min(scaleX, scaleY);

                                w *= scale;
                                h *= scale;
                                targetX = startX + (dx >= 0 ? w : -w);
                                targetY = startY + (dy >= 0 ? h : -h);
                            }

                            mx = targetX;
                            my = targetY;
                        }
                    }
                    currentX = mx;
                    currentY = my;
                }
            }

            onReleased: {
                if (isDragging) {
                    isDragging = false;
                    var x1 = Math.min(startX, currentX);
                    var y1 = Math.min(startY, currentY);
                    var w = Math.abs(startX - currentX);
                    var h = Math.abs(startY - currentY);

                    // Ignore very small clicks/drags to avoid accidental zoom on clicks.
                    // A second box, drawn on a view that is already zoomed, tightens that view.
                    if (w > 10 && h > 10)
                        root.zoomToBox(x1, y1, w, h);
                    root.isZoomSelectionMode = false;
                }
            }
        }

        // MouseArea for drawing the box that the camera turns to (the "3D" badge at the bottom right). It stays on until the badge is pressed again.
        MouseArea {
            id: aimMouseArea
            anchors.fill: parent
            enabled: root.isAimMode
            hoverEnabled: true
            cursorShape: Qt.CrossCursor

            property real startX: 0
            property real startY: 0
            property real currentX: 0
            property real currentY: 0
            property bool isDragging: false

            onPressed: {
                startX = mouse.x;
                startY = mouse.y;
                currentX = mouse.x;
                currentY = mouse.y;
                isDragging = true;
            }
            onPositionChanged: {
                if (isDragging) {
                    currentX = Math.max(0, Math.min(mouse.x, parent.width));
                    currentY = Math.max(0, Math.min(mouse.y, parent.height));
                }
            }
            onCanceled: isDragging = false
            onReleased: {
                if (!isDragging)
                    return;
                isDragging = false;
                var x1 = Math.min(startX, currentX);
                var y1 = Math.min(startY, currentY);
                var w = Math.abs(startX - currentX);
                var h = Math.abs(startY - currentY);
                // The mode stays on for the next box; the 3D badge turns it off.
                if (w <= 10 || h <= 10) {
                    root.showAimMessage(qsTr("Draw a bigger box on the picture."), true);
                    return;
                }
                // Tile pixels to fractions of the picture itself, leaving out any bars beside it.
                var fr = root.fittedVideoRect();
                function clamp01(v) { return Math.max(0, Math.min(1, v)); }
                var t = root.aimTarget;
                if (!t || fr.width <= 0 || fr.height <= 0)
                    return;
                root.aimSent = true;
                root.showAimMessage(qsTr("Sending the box to the camera..."), false);
                HikvisionPtzAim.aimAt(t.ip, t.http, t.user, t.pass, t.channel,
                                      clamp01((x1 - fr.x) / fr.width), clamp01((y1 - fr.y) / fr.height),
                                      clamp01((x1 + w - fr.x) / fr.width), clamp01((y1 + h - fr.y) / fr.height));
            }
        }

        Rectangle {
            visible: aimMouseArea.isDragging
            x: Math.min(aimMouseArea.startX, aimMouseArea.currentX)
            y: Math.min(aimMouseArea.startY, aimMouseArea.currentY)
            width: Math.abs(aimMouseArea.startX - aimMouseArea.currentX)
            height: Math.abs(aimMouseArea.startY - aimMouseArea.currentY)
            color: "#33ff7a00"
            border.color: "#ff7a00"
            border.width: 2
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 10
            width: aimBannerText.implicitWidth + 24
            height: aimBannerText.implicitHeight + 12
            radius: 6
            color: "#dd000000"
            border.width: 1
            border.color: root.aimFailed ? "#e74c3c" : "#ff7a00"
            visible: root.aimMessage !== "" || root.isAimMode
            Text {
                id: aimBannerText
                anchors.centerIn: parent
                font.pixelSize: 12
                font.bold: true
                color: root.aimFailed ? "#ff6b5b" : "#ffffff"
                text: root.aimMessage !== "" ? root.aimMessage : qsTr("3D on: drag a box on the picture to point the camera at it. Press 3D again to stop.")
            }
        }

        // MouseArea to handle middle-click drag (wheel click and drag) for panning in 1:1 mode and zoom mode
        MouseArea {
            id: middleDragMouseArea
            anchors.fill: parent
            acceptedButtons: Qt.MiddleButton
            enabled: root.isOneToOne || root.isZoomed
            cursorShape: containsPress ? Qt.ClosedHandCursor : Qt.OpenHandCursor

            property real lastX: 0
            property real lastY: 0

            onPressed: {
                lastX = mouse.x;
                lastY = mouse.y;
            }

            onPositionChanged: {
                if (pressed) {
                    var dx = mouse.x - lastX;
                    var dy = mouse.y - lastY;

                    if (root.isOneToOne) {
                        var videoW;
                        var videoH;
                        if (root.isQuickPlayback) {
                            videoW = quickPlaybackPlayerLoader.width;
                            videoH = quickPlaybackPlayerLoader.height;
                        } else {
                            var activeOutput = root.activePlayerIndex === 1 ? videoOutput1 : videoOutput2;
                            videoW = activeOutput.width;
                            videoH = activeOutput.height;
                        }

                        root.oneToOneX = Math.min(0, Math.max(parent.width - videoW, root.oneToOneX + dx));
                        root.oneToOneY = Math.min(0, Math.max(parent.height - videoH, root.oneToOneY + dy));
                    } else if (root.isZoomed && parent.width > 0 && parent.height > 0) {
                        root.panZoomBy(dx, dy);
                    }

                    lastX = mouse.x;
                    lastY = mouse.y;
                }
            }
        }

        // Selection rectangle outline
        Rectangle {
            id: selectionRect
            visible: zoomMouseArea.isDragging
            x: Math.min(zoomMouseArea.startX, zoomMouseArea.currentX)
            y: Math.min(zoomMouseArea.startY, zoomMouseArea.currentY)
            width: Math.abs(zoomMouseArea.startX - zoomMouseArea.currentX)
            height: Math.abs(zoomMouseArea.startY - zoomMouseArea.currentY)
            color: "#3300f5d4" // translucent cyan
            border.color: "#00f5d4" // solid cyan border
            border.width: 1
        }

        MouseArea {
            id: playerHoverArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton

            property bool isHovered: false

            function updateHoverState() {
                isHovered = containsMouse && !(typeof rootWindow !== "undefined" && rootWindow.cursorHidden);
            }

            onContainsMouseChanged: updateHoverState()
            onIsHoveredChanged: if (isHovered && root.isHikvision) root.checkAimLens()
            Connections {
                target: typeof rootWindow !== "undefined" ? rootWindow : null
                function onCursorHiddenChanged() { playerHoverArea.updateHoverState() }
            }
            Component.onCompleted: updateHoverState()

            // Symmetrically placed magnifying glass button overlay on the bottom right
            Item {
                id: viewportControls
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: 6
                    rightMargin: 6
                    bottomMargin: root.isQuickPlayback ? (quickPlaybackControlsPanel.height + 12) : 6
                }
                height: toolSize
                clip: true
                visible: (root.source !== "") && (root.talkActiveHere || talkVolumePopup.opened || ((!viewSettings.hoverControlIcons || playerHoverArea.isHovered) && !(typeof rootWindow !== "undefined" && rootWindow.cursorHidden)))

                // A full-size row is 24px. A narrow tile cannot hold every tool at that size, so they shrink together until the row fits.
                readonly property int toolCount: (talkBadge.visible ? 1 : 0) + (snapshotBadge.visible ? 1 : 0)
                    + (playbackBadge.visible ? 1 : 0) + (quickPlaybackToggleBadge.visible ? 1 : 0)
                    + (oneToOneBadge.visible ? 1 : 0) + (zoomBadge.visible ? 1 : 0)
                    + (ptzToggleBadge.visible ? 1 : 0) + (aimBadge.visible ? 1 : 0)
                // Quick playback keeps its own volume on the bar below, so this row does not also grow for it.
                readonly property bool showTileVolume: root.hasAudio && !root.isQuickPlayback
                readonly property int toolSize: {
                    var w = Math.max(0, width);
                    // Mute and full volume sit on the left of the same row, or minus and plus when the slider does not fit.
                    function fits(size, gap) {
                        var buttons = toolCount + (showTileVolume ? 2 : 0);
                        var gaps = Math.max(0, toolCount - 1) * gap;
                        if (showTileVolume) {
                            gaps += gap;
                            if (toolCount > 0)
                                gaps += gap;
                        }
                        return buttons * size + gaps <= w;
                    }
                    if (fits(24, 4))
                        return 24;
                    var s;
                    for (s = 23; s >= 16; --s) {
                        if (fits(s, 3))
                            return s;
                    }
                    for (s = 15; s >= 12; --s) {
                        if (fits(s, 2))
                            return s;
                    }
                    return 12;
                }
                readonly property int toolGap: toolSize >= 24 ? 4 : (toolSize >= 16 ? 3 : 2)
                readonly property int toolPad: Math.max(1, Math.round(toolSize * 5 / 24))
                readonly property int toolFont: Math.max(6, Math.round(toolSize * 10 / 24))

                Row {
                    id: volumeControl
                    anchors.right: actionButtons.left
                    anchors.rightMargin: viewportControls.toolGap
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: viewportControls.toolGap
                    visible: viewportControls.showTileVolume
                    clip: true

                    readonly property int availableWidth: Math.max(0, viewportControls.width - actionButtons.width - viewportControls.toolGap)
                    property bool showSlider: availableWidth >= viewportControls.toolSize * 2 + viewportControls.toolGap + 48

                    function setVolume(value) {
                        var v = Math.max(0, Math.min(1, value));
                        // A mute from this tile has to remember the level, so M can put that level back.
                        if (v <= 0 && root.volume > 0)
                            root.rememberAudible();
                        if (root.layoutModel && root.index !== -1) {
                            var vItem = root.layoutModel.get(root.index);
                            if (vItem)
                                vItem.volume = v;
                        } else {
                            root.volume = v;
                        }
                    }

                    // No room for the slider, so each click moves one tenth instead of jumping to silence or full.
                    function stepVolume(dir) {
                        var q = root.volume * 10;
                        var next = dir > 0 ? Math.floor(q + 0.001) + 1 : Math.ceil(q - 0.001) - 1;
                        setVolume(Math.max(0, Math.min(10, next)) / 10);
                    }

                    Control {
                        id: muteButton
                        implicitWidth: viewportControls.toolSize
                        implicitHeight: viewportControls.toolSize
                        padding: volumeControl.showSlider ? viewportControls.toolPad : 0
                        opacity: (!volumeControl.showSlider && root.volume <= 0.001) ? 0.4 : 1
                        focusPolicy: Qt.NoFocus

                        background: Rectangle {
                            radius: viewportControls.toolSize / 2
                            color: muteMouseArea.pressed ? "#4a5560" : (muteMouseArea.containsMouse ? "#3a4550" : "#cc121214")
                            border.color: (muteMouseArea.containsMouse || muteMouseArea.pressed) ? "#cc8898a6" : "#802a3540"
                            border.width: 1
                        }

                        contentItem: Item {
                            Image {
                                anchors.fill: parent
                                visible: volumeControl.showSlider
                                sourceSize: Qt.size(32, 32)
                                fillMode: Image.PreserveAspectFit
                                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ff3333' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5'></polygon><line x1='23' y1='9' x2='17' y2='15'></line><line x1='17' y1='9' x2='23' y2='15'></line></svg>"
                            }
                            Text {
                                anchors.fill: parent
                                visible: !volumeControl.showSlider
                                text: "-"
                                color: muteMouseArea.containsMouse ? "#00f5d4" : "#ffffff"
                                font.pixelSize: Math.max(8, Math.round(viewportControls.toolSize * 0.7))
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        MouseArea {
                            id: muteMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: playerHoverArea.updateHoverState()
                            onClicked: {
                                if (volumeControl.showSlider)
                                    volumeControl.setVolume(0);
                                else
                                    volumeControl.stepVolume(-1);
                            }
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: muteMouseArea.containsMouse
                        ToolTip.text: volumeControl.showSlider ? qsTr("LNG_00106") : qsTr("Lower the volume")
                    }

                    Slider {
                        id: volumeSlider
                        width: volumeControl.showSlider ? Math.min(110, volumeControl.availableWidth - viewportControls.toolSize * 2 - viewportControls.toolGap * 2) : 0
                        height: viewportControls.toolSize
                        visible: volumeControl.showSlider
                        padding: 0
                        from: 0.0
                        to: 1.0
                        value: root.volume
                        focusPolicy: Qt.NoFocus
                        onMoved: volumeControl.setVolume(value)

                        background: Rectangle {
                            x: volumeSlider.leftPadding
                            y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 110
                            implicitHeight: 4
                            width: volumeSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: "#1c242c"

                            Rectangle {
                                width: volumeSlider.visualPosition * parent.width
                                height: parent.height
                                color: "#00f5d4"
                                radius: 2
                                layer.enabled: true
                                layer.effect: Glow {
                                    radius: 4
                                    samples: 8
                                    color: "#00f5d4"
                                    transparentBorder: true
                                }
                            }
                        }

                        handle: Rectangle {
                            x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                            y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 12
                            implicitHeight: 12
                            radius: 6
                            color: volumeSlider.pressed ? "#ff9a00" : (sliderMouseArea.containsMouse ? "#ffaa00" : "#ff7a00")
                            border.color: "#ffffff"
                            border.width: volumeSlider.pressed ? 2 : 1
                        }

                        MouseArea {
                            id: sliderMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                            onContainsMouseChanged: playerHoverArea.updateHoverState()
                        }

                        Connections {
                            target: volumeSlider
                            function onPressedChanged() { playerHoverArea.updateHoverState() }
                        }
                    }

                    Control {
                        id: maxVolButton
                        implicitWidth: viewportControls.toolSize
                        implicitHeight: viewportControls.toolSize
                        padding: volumeControl.showSlider ? viewportControls.toolPad : 0
                        opacity: (!volumeControl.showSlider && root.volume >= 0.999) ? 0.4 : 1
                        focusPolicy: Qt.NoFocus

                        background: Rectangle {
                            radius: viewportControls.toolSize / 2
                            color: maxVolMouseArea.pressed ? "#4a5560" : (maxVolMouseArea.containsMouse ? "#3a4550" : "#cc121214")
                            border.color: (maxVolMouseArea.containsMouse || maxVolMouseArea.pressed) ? "#cc8898a6" : "#802a3540"
                            border.width: 1
                        }

                        contentItem: Item {
                            Image {
                                anchors.fill: parent
                                visible: volumeControl.showSlider
                                sourceSize: Qt.size(32, 32)
                                fillMode: Image.PreserveAspectFit
                                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5'></polygon><path d='M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07'></path></svg>"
                            }
                            Text {
                                anchors.fill: parent
                                visible: !volumeControl.showSlider
                                text: "+"
                                color: maxVolMouseArea.containsMouse ? "#00f5d4" : "#ffffff"
                                font.pixelSize: Math.max(8, Math.round(viewportControls.toolSize * 0.7))
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        MouseArea {
                            id: maxVolMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: playerHoverArea.updateHoverState()
                            onClicked: {
                                if (volumeControl.showSlider)
                                    volumeControl.setVolume(1);
                                else
                                    volumeControl.stepVolume(1);
                            }
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: maxVolMouseArea.containsMouse
                        ToolTip.text: volumeControl.showSlider ? qsTr("LNG_00157") : qsTr("Raise the volume")
                    }
                }

                Row {
                    id: actionButtons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: viewportControls.toolGap

                    Control {
                        id: talkBadge

                        implicitWidth: viewportControls.toolSize
                        implicitHeight: viewportControls.toolSize
                        padding: viewportControls.toolPad
                        visible: root.source !== "" && root.isHikvision && !root.isQuickPlayback
                                 && !(typeof generalSettings !== "undefined" && generalSettings.disableTalk)
                        onVisibleChanged: playerHoverArea.updateHoverState()

                        background: Rectangle {
                            radius: viewportControls.toolSize / 2
                            color: root.talkActiveHere ?
                                (HikvisionTalk.live ? "#55e74c3c" : "#44ff7a00") :
                                (talkMouseArea.pressed ? "#4a5560" : (talkMouseArea.containsMouse ? "#3a4550" : "#cc121214"))
                            border.color: root.talkActiveHere ?
                                (HikvisionTalk.live ? "#ffe74c3c" : "#ccff7a00") :
                                ((talkMouseArea.containsMouse || talkMouseArea.pressed) ? "#cc8898a6" : "#802a3540")
                            border.width: 1
                        }

                        contentItem: Image {
                            sourceSize: Qt.size(32, 32)
                            fillMode: Image.PreserveAspectFit
                            source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + (root.talkActiveHere ? (HikvisionTalk.live ? "%23ff6b5b" : "%23ff7a00") : (talkMouseArea.containsMouse ? "%2300f5d4" : "%23ffffff")) + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z'></path><path d='M19 10v2a7 7 0 0 1-14 0v-2'></path><line x1='12' y1='19' x2='12' y2='23'></line><line x1='8' y1='23' x2='16' y2='23'></line></svg>"
                        }

                        MouseArea {
                            id: talkMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: {
                                playerHoverArea.updateHoverState();
                                if (containsMouse)
                                    root.resolveTalkTarget();
                            }
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onPressed: {
                                if (mouse.button === Qt.RightButton)
                                    root.openTalkVolume();
                                else
                                    root.startTalk();
                            }
                            onReleased: {
                                if (mouse.button === Qt.LeftButton)
                                    root.stopTalk();
                            }
                            onCanceled: root.stopTalk()
                        }

                        Popup {
                            id: talkVolumePopup
                            x: parent.width - width
                            y: -height - 6
                            width: 230
                            padding: 10
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                            onClosed: talkVolumeSaveTimer.stop()

                            background: Rectangle {
                                color: "#ee141a21"
                                border.color: "#00f5d4"
                                border.width: 1
                                radius: 8
                            }

                            contentItem: Column {
                                spacing: 6

                                Text {
                                    width: parent.width
                                    color: "#ffffff"
                                    font.pixelSize: 11
                                    font.bold: true
                                    wrapMode: Text.Wrap
                                    text: root.talkSpeakerVolume >= 0
                                          ? qsTr("Camera speaker volume: %1").arg(root.talkSpeakerVolume)
                                          : qsTr("Camera speaker volume")
                                }

                                Slider {
                                    id: talkVolumeSlider
                                    width: parent.width
                                    from: 0
                                    to: 100
                                    stepSize: 1
                                    enabled: root.talkSpeakerVolume >= 0
                                    value: root.talkSpeakerVolume >= 0 ? root.talkSpeakerVolume : 0
                                    onMoved: {
                                        root.talkSpeakerVolume = Math.round(value);
                                        root.talkVolumeStatus = "";
                                        talkVolumeSaveTimer.restart();
                                    }
                                }

                                Text {
                                    width: parent.width
                                    visible: text !== ""
                                    text: root.talkVolumeStatus
                                    color: "#8898a6"
                                    font.pixelSize: 10
                                    wrapMode: Text.Wrap
                                }

                                Text {
                                    width: parent.width
                                    text: qsTr("Right-click the microphone button to open this. The volume is saved on the camera.")
                                    color: "#5f6e7b"
                                    font.pixelSize: 9
                                    wrapMode: Text.Wrap
                                }
                            }
                        }

                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: talkMouseArea.containsMouse && !root.talkActiveHere
                        ToolTip.text: qsTr("Hold to talk through the camera speaker. Right-click for the camera speaker volume.")
                    }

                    Control {
                    id: snapshotBadge

                    property bool isSavingSnapshot: false

                    Timer {
                        id: snapshotBadgeTimer
                        interval: 1000
                        onTriggered: snapshotBadge.isSavingSnapshot = false
                    }

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== ""

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: snapshotBadge.isSavingSnapshot ?
                            (snapshotMouseAreaBtn.pressed ? "#44ff7a00" : (snapshotMouseAreaBtn.containsMouse ? "#33ff7a00" : "#22ff7a00")) :
                            (snapshotMouseAreaBtn.pressed ? "#4a5560" : (snapshotMouseAreaBtn.containsMouse ? "#3a4550" : "#cc121214"))
                        border.color: snapshotBadge.isSavingSnapshot ?
                            "#ccff7a00" :
                            ((snapshotMouseAreaBtn.containsMouse || snapshotMouseAreaBtn.pressed) ? "#cc8898a6" : "#802a3540")
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: snapshotBadge.isSavingSnapshot ?
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ff7a00' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z'></path><circle cx='12' cy='13' r='4'></circle></svg>" :
                            (snapshotMouseAreaBtn.containsMouse ?
                                "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z'></path><circle cx='12' cy='13' r='4'></circle></svg>" :
                                "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z'></path><circle cx='12' cy='13' r='4'></circle></svg>")
                    }

                    MouseArea {
                        id: snapshotMouseAreaBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            // Quick playback + zoomed: let the user pick full or zoomed image.
                            if (root.isQuickPlayback && root.isZoomed) {
                                snapshotChoiceMenu.popup();
                            } else {
                                root.takeSnapshot(false);
                            }
                        }
                    }

                    Menu {
                        id: snapshotChoiceMenu
                        MenuItem {
                            text: qsTr("Save full image")
                            onTriggered: root.captureCurrentFrameAndNotify("QUICK_PLAYBACK", false)
                        }
                        MenuItem {
                            text: qsTr("Save zoomed view")
                            onTriggered: root.captureCurrentFrameAndNotify("QUICK_PLAYBACK", true)
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: snapshotMouseAreaBtn.containsMouse
                    ToolTip.text: qsTr("LNG_00156")
                }

                Control {
                    id: playbackBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== "" && root.isHikvision
                    onVisibleChanged: playerHoverArea.updateHoverState()

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: playbackMouseAreaBtn.pressed ? "#4a5560" : (playbackMouseAreaBtn.containsMouse ? "#3a4550" : "#cc121214")
                        border.color: (playbackMouseAreaBtn.containsMouse || playbackMouseAreaBtn.pressed) ? "#cc8898a6" : "#802a3540"
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: playbackMouseAreaBtn.containsMouse ?
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='5 3 19 12 5 21 5 3'></polygon></svg>" :
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='5 3 19 12 5 21 5 3'></polygon></svg>"
                    }

                    MouseArea {
                        id: playbackMouseAreaBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            var recInfo = {
                                "ip": root.recorderIp,
                                "port": root.sdkPort || root.recorderPort || 8000,
                                "sdkPort": root.sdkPort || root.recorderPort || 8000,
                                "httpPort": root.httpPort || 80,
                                "rtspPort": root.rtspPort || 554,
                                "username": root.username,
                                "password": root.password
                            };
                            var camName = root.cameraNameInfo || ("Camera " + root.channelId);

                            rootWindow.openPlaybackWindow(recInfo, root.channelId, camName);
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: playbackMouseAreaBtn.containsMouse
                    ToolTip.text: qsTr("LNG_00193")
                }

                Control {
                    id: quickPlaybackToggleBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== "" && root.isHikvision
                    onVisibleChanged: playerHoverArea.updateHoverState()

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: root.isQuickPlayback ?
                            (quickPlaybackToggleMouseArea.pressed ? "#4400f5d4" : (quickPlaybackToggleMouseArea.containsMouse ? "#3300f5d4" : "#2200f5d4")) :
                            (quickPlaybackToggleMouseArea.pressed ? "#4a5560" : (quickPlaybackToggleMouseArea.containsMouse ? "#3a4550" : "#cc121214"))
                        border.color: root.isQuickPlayback ?
                            "#cc00f5d4" :
                            ((quickPlaybackToggleMouseArea.containsMouse || quickPlaybackToggleMouseArea.pressed) ? "#cc8898a6" : "#802a3540")
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: (root.isQuickPlayback || quickPlaybackToggleMouseArea.containsMouse) ?
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M3 2v6h6'></path><path d='M3 13a9 9 0 1 0 3-7.7L3 8'></path></svg>" :
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M3 2v6h6'></path><path d='M3 13a9 9 0 1 0 3-7.7L3 8'></path></svg>"
                    }

                    MouseArea {
                        id: quickPlaybackToggleMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            root.isQuickPlayback = !root.isQuickPlayback;
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: quickPlaybackToggleMouseArea.containsMouse
                    ToolTip.text: root.isQuickPlayback ? qsTr("LNG_00192") : qsTr("LNG_00191")
                }

                Control {
                    id: oneToOneBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== ""

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: root.isOneToOne ?
                            (oneToOneMouseAreaBtn.pressed ? "#4400f5d4" : (oneToOneMouseAreaBtn.containsMouse ? "#3300f5d4" : "#2200f5d4")) :
                            (oneToOneMouseAreaBtn.pressed ? "#4a5560" : (oneToOneMouseAreaBtn.containsMouse ? "#3a4550" : "#cc121214"))
                        border.color: root.isOneToOne ?
                            "#cc00f5d4" :
                            ((oneToOneMouseAreaBtn.containsMouse || oneToOneMouseAreaBtn.pressed) ? "#cc8898a6" : "#802a3540")
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: (root.isOneToOne || oneToOneMouseAreaBtn.containsMouse) ?
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M6 8.5L8 7v10M16 8.5L18 7v10'></path><circle cx='12' cy='10' r='1' fill='%2300f5d4' stroke='none'></circle><circle cx='12' cy='14' r='1' fill='%2300f5d4' stroke='none'></circle></svg>" :
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M6 8.5L8 7v10M16 8.5L18 7v10'></path><circle cx='12' cy='10' r='1' fill='%23ffffff' stroke='none'></circle><circle cx='12' cy='14' r='1' fill='%23ffffff' stroke='none'></circle></svg>"
                    }

                    MouseArea {
                        id: oneToOneMouseAreaBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            root.isOneToOne = !root.isOneToOne;
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: oneToOneMouseAreaBtn.containsMouse
                    ToolTip.text: root.isOneToOne ? qsTr("Exit 1:1 pixel view") : qsTr("Show the camera at its actual pixel size")
                }

                Control {
                    id: zoomBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== ""

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: root.isZoomed ?
                            (zoomMouseAreaBtn.pressed ? "#44ff3333" : (zoomMouseAreaBtn.containsMouse ? "#33ff3333" : "#22121214")) :
                            (root.isZoomSelectionMode ?
                                (zoomMouseAreaBtn.pressed ? "#4400f5d4" : (zoomMouseAreaBtn.containsMouse ? "#3300f5d4" : "#2200f5d4")) :
                                (zoomMouseAreaBtn.pressed ? "#4a5560" : (zoomMouseAreaBtn.containsMouse ? "#3a4550" : "#cc121214"))
                            )
                        border.color: root.isZoomed ?
                            (zoomMouseAreaBtn.containsMouse ? "#ccff3333" : "#80ff3333") :
                            (root.isZoomSelectionMode ?
                                "#cc00f5d4" :
                                ((zoomMouseAreaBtn.containsMouse || zoomMouseAreaBtn.pressed) ? "#cc8898a6" : "#802a3540")
                            )
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: root.isZoomed ?
                            "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ff3333' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='8'></circle><line x1='21' y1='21' x2='16.65' y2='16.65'></line><line x1='8' y1='11' x2='14' y2='11'></line></svg>" :
                            ((root.isZoomSelectionMode || zoomMouseAreaBtn.containsMouse) ?
                                "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='8'></circle><line x1='21' y1='21' x2='16.65' y2='16.65'></line><line x1='11' y1='8' x2='11' y2='14'></line><line x1='8' y1='11' x2='14' y2='11'></line></svg>" :
                                "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='8'></circle><line x1='21' y1='21' x2='16.65' y2='16.65'></line><line x1='11' y1='8' x2='11' y2='14'></line><line x1='8' y1='11' x2='14' y2='11'></line></svg>"
                            )
                    }

                    MouseArea {
                        id: zoomMouseAreaBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            if (root.isZoomed) {
                                // Reset zoom
                                root.zoomX = 0;
                                root.zoomY = 0;
                                root.zoomWidth = 1;
                                root.zoomHeight = 1;
                                root.isZoomed = false;
                                root.isZoomSelectionMode = false;
                            } else {
                                // Toggle selection mode
                                root.isZoomSelectionMode = !root.isZoomSelectionMode;
                            }
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: zoomMouseAreaBtn.containsMouse
                    ToolTip.text: root.isZoomed ? qsTr("LNG_00153") : (root.isZoomSelectionMode ? qsTr("LNG_00190") : qsTr("LNG_00189"))
                }
                Control {
                    id: ptzToggleBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: viewportControls.toolPad
                    visible: root.source !== "" && root.isHikvision
                    onVisibleChanged: playerHoverArea.updateHoverState()

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: root.ptzPadVisible ?
                            (ptzToggleMouseArea.pressed ? "#44ff7a00" : (ptzToggleMouseArea.containsMouse ? "#33ff7a00" : "#22ff7a00")) :
                            (ptzToggleMouseArea.pressed ? "#4a5560" : (ptzToggleMouseArea.containsMouse ? "#3a4550" : "#cc121214"))
                        border.color: root.ptzPadVisible ?
                            "#ccff7a00" :
                            ((ptzToggleMouseArea.containsMouse || ptzToggleMouseArea.pressed) ? "#cc8898a6" : "#802a3540")
                        border.width: 1
                    }

                    contentItem: Image {
                        sourceSize: Qt.size(32, 32)
                        fillMode: Image.PreserveAspectFit
                        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + (root.ptzPadVisible || ptzToggleMouseArea.containsMouse ? "%2300f5d4" : "%23ffffff") + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polyline points='5 9 2 12 5 15'></polyline><polyline points='9 5 12 2 15 5'></polyline><polyline points='15 19 12 22 9 19'></polyline><polyline points='19 9 22 12 19 15'></polyline><line x1='2' y1='12' x2='22' y2='12'></line><line x1='12' y1='2' x2='12' y2='22'></line></svg>"
                    }

                    MouseArea {
                        id: ptzToggleMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: root.ptzPadVisible = !root.ptzPadVisible
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: ptzToggleMouseArea.containsMouse
                    ToolTip.text: qsTr("PTZ controls")
                }

                Control {
                    id: aimBadge

                    implicitWidth: viewportControls.toolSize
                    implicitHeight: viewportControls.toolSize
                    padding: 0
                    // On any PTZ lens that offers 3D positioning (the wide lens and the close-up lens of a two-lens PTZ); not while zoomed in or at 1:1,
                    // where a box would not match the picture.
                    visible: root.source !== "" && root.isHikvision && root.aimWide && root.aimWideFor === root.aimKey && !root.isQuickPlayback
                    opacity: (root.isZoomed || root.isOneToOne) ? 0.4 : 1.0
                    onVisibleChanged: playerHoverArea.updateHoverState()

                    background: Rectangle {
                        radius: viewportControls.toolSize / 2
                        color: root.isAimMode ?
                            (aimMouseAreaBtn.pressed ? "#44ff7a00" : (aimMouseAreaBtn.containsMouse ? "#33ff7a00" : "#22ff7a00")) :
                            (aimMouseAreaBtn.pressed ? "#4a5560" : (aimMouseAreaBtn.containsMouse ? "#3a4550" : "#cc121214"))
                        border.color: root.isAimMode ? "#ccff7a00" :
                            ((aimMouseAreaBtn.containsMouse || aimMouseAreaBtn.pressed) ? "#cc8898a6" : "#802a3540")
                        border.width: 1
                    }

                    contentItem: Text {
                        text: "3D"
                        font.pixelSize: viewportControls.toolFont
                        font.bold: true
                        color: (root.isAimMode || aimMouseAreaBtn.containsMouse) ? "#00f5d4" : "#ffffff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    MouseArea {
                        id: aimMouseAreaBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: playerHoverArea.updateHoverState()
                        onClicked: {
                            if (root.isZoomed || root.isOneToOne) {
                                root.showAimMessage(qsTr("Reset the zoom first, then draw the box."), true);
                                return;
                            }
                            root.isAimMode = !root.isAimMode;
                            if (root.isAimMode)
                                root.isZoomSelectionMode = false;
                        }
                    }

                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: aimMouseAreaBtn.containsMouse
                    ToolTip.text: root.isAimMode ? qsTr("3D is on. Press to turn it off") : (root.aimIsWide ? qsTr("Point the camera: draw a box on this wide view and the PTZ lens turns and zooms to it")
                                                                                  : qsTr("Re-aim this lens: draw a box and the camera centers on it and zooms in"))
                }

                }
            }

            // --- PTZ CONTROL PAD (pan/tilt/zoom for PTZ-capable Hikvision cameras) ---
            Rectangle {
                id: ptzPad

                anchors {
                    left: parent.left
                    leftMargin: 8
                    bottom: parent.bottom
                    bottomMargin: 52
                }

                property int pressedCount: 0
                property string presetEntry: ""
                readonly property real uiScale: Math.max(0.62, Math.min(1.0, Math.min(root.width, root.height) / 430))

                // Only while the pointer is over this tile: the cursor-hidden flag belongs to the whole window, so without this every
                // tile's pad came back when the mouse moved in another tile. A pressed button keeps it, even if the pointer slips off.
                visible: root.ptzPadVisible && root.isHikvision
                         && (pressedCount > 0 || (playerHoverArea.containsMouse && !(typeof rootWindow !== "undefined" && rootWindow.cursorHidden)))
                onVisibleChanged: playerHoverArea.updateHoverState()
                color: "#66121214"
                border.color: "#ccff7a00"
                border.width: 1
                radius: 8
                implicitWidth: ptzPadRow.implicitWidth * uiScale + 16
                implicitHeight: ptzPadRow.implicitHeight * uiScale + 16

                transform: Scale {
                    origin.x: 0
                    origin.y: ptzPad.height
                    xScale: ptzPad.uiScale
                    yScale: ptzPad.uiScale
                }

                function ptzCommand(command, stop) {
                    if (root.isHikvision && root.recorderIp !== "") {
                        HikvisionManager.ptzZoom(root.recorderIp, root.recorderPort, root.username, root.password, root.channelId, command, stop);
                    }
                }

                function ptzPresetCommand(command, presetIndex) {
                    if (root.isHikvision && root.recorderIp !== "" && presetIndex > 0) {
                        HikvisionManager.ptzPreset(root.recorderIp, root.recorderPort, root.username, root.password, root.channelId, command, presetIndex);
                    }
                }

                function appendPresetDigit(digit) {
                    var next = presetEntry + digit;
                    var value = parseInt(next);
                    presetEntry = (isNaN(value) || value <= 0) ? "" : String(Math.min(value, 255));
                }

                function ptzIconSource(icon) {
                    var stroke = (icon === "stop") ? "%23ff5555" : "%2300f5d4";
                    var body = "";
                    switch (icon) {
                    case "up": body = "<polyline points='18 15 12 9 6 15'></polyline>"; break;
                    case "down": body = "<polyline points='6 9 12 15 18 9'></polyline>"; break;
                    case "left": body = "<polyline points='15 18 9 12 15 6'></polyline>"; break;
                    case "right": body = "<polyline points='9 18 15 12 9 6'></polyline>"; break;
                    case "zoomin": body = "<line x1='12' y1='5' x2='12' y2='19'></line><line x1='5' y1='12' x2='19' y2='12'></line>"; break;
                    case "zoomout": body = "<line x1='5' y1='12' x2='19' y2='12'></line>"; break;
                    case "focusnear": body = "<circle cx='12' cy='12' r='3' fill='%2300f5d4'></circle><circle cx='12' cy='12' r='8'></circle>"; break;
                    case "focusfar": body = "<polyline points='2 19 8 9 13 16 16 12 22 19'></polyline><circle cx='18' cy='6' r='1.5'></circle>"; break;
                    case "stop": body = "<rect x='7' y='7' width='10' height='10' rx='1'></rect>"; break;
                    }
                    return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + stroke + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'>" + body + "</svg>";
                }

                Row {
                    id: ptzPadRow
                    anchors.centerIn: parent
                    spacing: 8
                    Grid {
                        columns: 3
                        rowSpacing: 4
                        columnSpacing: 4
                        Repeater {
                            model: [
                                { type: "empty" },
                                { type: "move", icon: "up", cmd: 21 },
                                { type: "empty" },
                                { type: "move", icon: "left", cmd: 23 },
                                { type: "stop", icon: "stop" },
                                { type: "move", icon: "right", cmd: 24 },
                                { type: "empty" },
                                { type: "move", icon: "down", cmd: 22 },
                                { type: "empty" },
                                { type: "move", icon: "zoomout", cmd: 12, tip: qsTr("Zoom out") },
                                { type: "aim" }, // the 3D box button: no PTZ command, it turns the 3D mode on and off (shown only on a lens that offers it)
                                { type: "move", icon: "zoomin", cmd: 11, tip: qsTr("Zoom in") },
                                { type: "move", icon: "focusnear", cmd: 13, tip: qsTr("Focus near") },
                                { type: "empty" },
                                { type: "move", icon: "focusfar", cmd: 14, tip: qsTr("Focus far") }
                            ]
                            delegate: Item {
                                implicitWidth: 30
                                implicitHeight: 30
                                Control {
                                    anchors.fill: parent
                                    visible: modelData.type !== "empty" && (modelData.type !== "aim" || (root.aimWide && root.aimWideFor === root.aimKey))
                                    focusPolicy: Qt.NoFocus
                                    opacity: (modelData.type === "aim" && (root.isZoomed || root.isOneToOne)) ? 0.4 : 1.0
                                    ToolTip.visible: (modelData.tip !== undefined || modelData.type === "aim") && moveArea.containsMouse
                                    ToolTip.text: modelData.type === "aim"
                                                  ? (root.isAimMode ? qsTr("3D is on. Press to turn it off")
                                                                    : (root.aimIsWide ? qsTr("Point the camera: draw a box on this wide view and the PTZ lens turns and zooms to it")
                                                                                      : qsTr("Re-aim this lens: draw a box and the camera centers on it and zooms in")))
                                                  : (modelData.tip !== undefined ? modelData.tip : "")
                                    background: Rectangle {
                                        radius: 15
                                        color: modelData.type === "stop" ? "#44ff3333" : ((moveArea.pressed || (modelData.type === "aim" && root.isAimMode)) ? "#44ff7a00" : (moveArea.containsMouse ? "#33ff7a00" : "#cc121214"))
                                        border.color: modelData.type === "stop" ? "#ccff3333" : ((moveArea.containsMouse || moveArea.pressed || (modelData.type === "aim" && root.isAimMode)) ? "#ccff7a00" : "#802a3540")
                                    }
                                    contentItem: Image {
                                        anchors.centerIn: parent
                                        sourceSize: Qt.size(32, 32)
                                        fillMode: Image.PreserveAspectFit
                                        visible: modelData.type !== "aim"
                                        source: modelData.type === "aim" ? "" : ptzPad.ptzIconSource(modelData.icon)
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: modelData.type === "aim"
                                        text: "3D"
                                        font.pixelSize: 10
                                        font.bold: true
                                        color: (root.isAimMode || moveArea.containsMouse) ? "#00f5d4" : "#ffffff"
                                    }
                                    MouseArea {
                                        id: moveArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.type !== "aim")
                                                return;
                                            if (root.isZoomed || root.isOneToOne) {
                                                root.showAimMessage(qsTr("Reset the zoom first, then draw the box."), true);
                                                return;
                                            }
                                            root.isAimMode = !root.isAimMode;
                                            if (root.isAimMode)
                                                root.isZoomSelectionMode = false;
                                        }
                                        onPressed: {
                                            if (modelData.type === "aim")
                                                return;
                                            ptzPad.pressedCount++;
                                            if (modelData.type === "stop")
                                                [11, 12, 13, 14, 21, 22, 23, 24].forEach(function(c) { ptzPad.ptzCommand(c, true); });
                                            else
                                                ptzPad.ptzCommand(modelData.cmd, false);
                                        }
                                        onReleased: {
                                            if (modelData.type === "aim")
                                                return;
                                            ptzPad.pressedCount = Math.max(0, ptzPad.pressedCount - 1);
                                            if (modelData.type === "move")
                                                ptzPad.ptzCommand(modelData.cmd, true);
                                        }
                                        onCanceled: {
                                            if (modelData.type === "aim")
                                                return;
                                            ptzPad.pressedCount = Math.max(0, ptzPad.pressedCount - 1);
                                            if (modelData.type === "move")
                                                ptzPad.ptzCommand(modelData.cmd, true);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Column {
                        spacing: 4
                        Rectangle {
                            width: 102
                            height: 22
                            radius: 4
                            color: "#cc121214"
                            border.color: "#802a3540"
                            Text {
                                anchors.centerIn: parent
                                text: ptzPad.presetEntry === "" ? qsTr("Preset") : ptzPad.presetEntry
                                color: ptzPad.presetEntry === "" ? "#8898a6" : "#eeeeee"
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }
                        Grid {
                            columns: 3
                            rowSpacing: 3
                            columnSpacing: 3
                            Repeater {
                                model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "⌫"]
                                delegate: Button {
                                    width: 32
                                    height: 24
                                    text: modelData
                                    focusPolicy: Qt.NoFocus
                                    onClicked: {
                                        if (modelData === "C")
                                            ptzPad.presetEntry = "";
                                        else if (modelData === "⌫")
                                            ptzPad.presetEntry = ptzPad.presetEntry.slice(0, -1);
                                        else
                                            ptzPad.appendPresetDigit(modelData);
                                    }
                                }
                            }
                        }
                        Row {
                            spacing: 4
                            Button {
                                width: 49
                                height: 24
                                text: qsTr("Go")
                                enabled: ptzPad.presetEntry !== ""
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    ptzPad.ptzPresetCommand(39, parseInt(ptzPad.presetEntry));
                                    ptzPad.presetEntry = "";
                                }
                            }
                            Button {
                                width: 49
                                height: 24
                                text: qsTr("Save")
                                enabled: ptzPad.presetEntry !== ""
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    ptzPad.ptzPresetCommand(8, parseInt(ptzPad.presetEntry));
                                    ptzPad.presetEntry = "";
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- QUICK PLAYBACK CONTROLS PANEL ---
        Rectangle {
            id: quickPlaybackControlsPanel
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 46
            color: root.isFullScreen ? "#801c242c" : "#661c242c"
            visible: root.isQuickPlayback

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onPressed: mouse.accepted = true
                onReleased: mouse.accepted = true
                onDoubleClicked: mouse.accepted = true
            }

            Slider {
                id: qpSlider
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: 18
                from: 0
                to: 1800
                value: root.quickPlaybackOffset
                focusPolicy: Qt.NoFocus
                padding: 0
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                leftInset: 0
                rightInset: 0
                topInset: 0
                bottomInset: 0
                
                onPressedChanged: {
                    if (pressed) {
                        if (quickPlaybackPlayerLoader.item) {
                            quickPlaybackPlayerLoader.item.pause();
                        }
                    } else {
                        root.quickPlaybackOffset = value;
                        var seekTime = new Date(root.quickPlaybackActivationTime.getTime() - (1800 - root.quickPlaybackOffset) * 1000);
                        if (quickPlaybackPlayerLoader.item) {
                            quickPlaybackPlayerLoader.item.playAtTime(seekTime);
                            if (root.quickPlaybackSpeed !== 1) {
                                quickPlaybackPlayerLoader.item.setPlaybackSpeed(root.quickPlaybackSpeed);
                            }
                            if (!root.isQuickPlaybackPaused) {
                                quickPlaybackPlayerLoader.item.resume();
                            }
                        }
                    }
                }
                onMoved: {
                    if (pressed) {
                        root.quickPlaybackOffset = value;
                    }
                }

                background: Rectangle {
                    anchors.fill: parent
                    color: "#330a0a0c"

                    Canvas {
                        id: qpTimelineCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);

                            // 1. Availability segments
                            ctx.fillStyle = root.isFullScreen ? "rgba(0, 245, 212, 0.55)" : "rgba(0, 245, 212, 0.45)";
                            for (var k = 0; k < root.quickPlaybackSegments.length; k++) {
                                var seg = root.quickPlaybackSegments[k];
                                if (!seg) continue;
                                var windowStartMs = root.quickPlaybackActivationTime ? (root.quickPlaybackActivationTime.getTime() - 1800000) : 0;
                                var windowEndMs = root.quickPlaybackActivationTime ? root.quickPlaybackActivationTime.getTime() : 0;
                                var segStartMs = Math.max(windowStartMs, seg.startTime);
                                var segEndMs = Math.min(windowEndMs, seg.endTime);
                                if (segStartMs < segEndMs && root.quickPlaybackActivationTime) {
                                    var x1 = ((segStartMs - windowStartMs) / 1800000) * width;
                                    var w = ((segEndMs - segStartMs) / 1800000) * width;
                                    ctx.fillRect(x1, 0, w, height);
                                }
                            }

                            // 1b. Event markers (motion, line crossing, etc.)
                            if (root.quickPlaybackActivationTime) {
                                var evWindowEnd = root.quickPlaybackActivationTime.getTime();
                                var evWindowStart = evWindowEnd - 1800000;
                                for (var ki = 0; ki < rootWindow.eventKindOrder.length; ki++) {
                                    var kindNow = rootWindow.eventKindOrder[ki];
                                    ctx.fillStyle = rootWindow.eventKindColor(kindNow);
                                    for (var ei = 0; ei < root.quickPlaybackEvents.length; ei++) {
                                        var ev = root.quickPlaybackEvents[ei];
                                        if (!ev || (ev.kind || "motion") !== kindNow) continue;
                                        if (ev.log && !rootWindow.overlapsRecording(root.quickPlaybackSegments, ev.startTime, ev.endTime)) continue;
                                        var evStart = Math.max(evWindowStart, ev.startTime);
                                        var evEnd = Math.min(evWindowEnd, ev.endTime);
                                        if (evStart > evEnd) continue;
                                        var ex = ((evStart - evWindowStart) / 1800000) * width;
                                        var ew = Math.max(3, ((evEnd - evStart) / 1800000) * width);
                                        ctx.fillRect(Math.min(ex, width - ew), ev.log ? (height - 8) / 2 : 0, ew, ev.log ? (height - 8) / 2 : height - 8);
                                    }
                                }
                            }

                            // 2. Timeline ticks & minute scale
                            var windowStartMs = root.quickPlaybackActivationTime ? (root.quickPlaybackActivationTime.getTime() - 1800000) : 0;
                            var windowEndMs = root.quickPlaybackActivationTime ? root.quickPlaybackActivationTime.getTime() : 0;
                            var startMinMs = Math.ceil(windowStartMs / 60000) * 60000;
                            var endMinMs = Math.floor(windowEndMs / 60000) * 60000;

                            for (var mMs = startMinMs; mMs <= endMinMs; mMs += 60000) {
                                var tx = ((mMs - windowStartMs) / 1800000) * width;
                                var d = new Date(mMs);
                                var isFiveMin = (d.getMinutes() % 5 === 0);
                                
                                ctx.fillStyle = isFiveMin ? "#ffffff" : "rgba(255, 255, 255, 0.5)";
                                var tickHeight = isFiveMin ? 6 : 3;
                                ctx.fillRect(tx, height - tickHeight, 1, tickHeight);
                                
                                if (isFiveMin) {
                                    var displayH = d.getHours();
                                    var displayM = d.getMinutes();
                                    var timeStr = (displayH < 10 ? "0" : "") + displayH + ":" + (displayM < 10 ? "0" : "") + displayM;
                                    
                                    ctx.font = "bold 9px sans-serif";
                                    
                                    // Black shadow/outline for extreme contrast on video background
                                    ctx.fillStyle = "#000000";
                                    ctx.fillText(timeStr, tx - 12 + 1, height - 8 + 1);
                                    
                                    // White foreground text
                                    ctx.fillStyle = "#ffffff";
                                    ctx.fillText(timeStr, tx - 12, height - 8);
                                }
                            }
                        }

                        Connections {
                            target: root
                            function onQuickPlaybackSegmentsChanged() { qpTimelineCanvas.requestPaint(); }
                            function onQuickPlaybackEventsChanged() { qpTimelineCanvas.requestPaint(); }
                            function onQuickPlaybackActivationTimeChanged() { qpTimelineCanvas.requestPaint(); }
                        }
                    }
                    
                    Rectangle {
                        width: qpSlider.visualPosition * parent.width
                        height: parent.height
                        color: "#00f5d4"
                        opacity: 0.1
                    }
                }
                
                handle: Rectangle {
                    x: qpSlider.leftPadding + qpSlider.visualPosition * qpSlider.availableWidth - width / 2
                    y: qpSlider.topPadding
                    implicitWidth: 2
                    implicitHeight: 18
                    color: "red"
                }
            }

            RowLayout {
                id: qpButtonsRow
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: 8
                    rightMargin: 8
                    bottomMargin: 2
                }
                height: 24
                spacing: 8

                Text {
                    id: qpTimeDisplay
                    Layout.minimumWidth: 100
                    color: "#ffffff"
                    font.pixelSize: 11
                    font.bold: true
                    visible: parent.width > 250
                    text: {
                        if (!root.quickPlaybackActivationTime) return "--:--:-- (now)";
                        var currentD = new Date(root.quickPlaybackActivationTime.getTime() - (1800 - root.quickPlaybackOffset) * 1000);
                        return root.formatTime(currentD) + " (" + root.formatRelativeTime(root.quickPlaybackOffset) + ")";
                    }
                }

                Item { Layout.fillWidth: true }

                Row {
                    id: qpSeekRow
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    visible: qpButtonsRow.width > 400

                    Repeater {
                        model: [
                            { label: "-10m", delta: -600, tip: qsTr("Rewind 10 minutes") },
                            { label: "-2m", delta: -120, tip: qsTr("Rewind 2 minutes") },
                            { label: "-30s", delta: -30, tip: qsTr("Rewind 30 seconds") },
                            { label: "-5s", delta: -5, tip: qsTr("Rewind 5 seconds") },
                            { label: "+5s", delta: 5, tip: qsTr("Forward 5 seconds") },
                            { label: "+30s", delta: 30, tip: qsTr("Forward 30 seconds") },
                            { label: "+2m", delta: 120, tip: qsTr("Forward 2 minutes") },
                            { label: "+10m", delta: 600, tip: qsTr("Forward 10 minutes") }
                        ]
                        delegate: CctvButton {
                            focusPolicy: Qt.NoFocus
                            text: modelData.label
                            isMini: true
                            isTransparent: true
                            onClicked: root.seekQuickPlayback(modelData.delta)
                            ToolTip.delay: Compact.toolTipDelay
                            ToolTip.timeout: Compact.toolTipTimeout
                            ToolTip.visible: hovered
                            ToolTip.text: modelData.tip
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Row {
                    id: qpVolumeRow
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 4
                    visible: !(typeof generalSettings !== "undefined" && generalSettings.disableAudio)
                    // The seek buttons already fill a narrow bar, so those tiles get tenth-steps instead of a slider.
                    readonly property bool showSlider: qpButtonsRow.width > 640

                    function restoreVolume() {
                        var cell = root.parent && root.parent.parent;
                        var back = (cell && cell.audibleVolume > 0) ? cell.audibleVolume : 1;
                        volumeControl.setVolume(back);
                    }

                    CctvButton {
                        focusPolicy: Qt.NoFocus
                        isMini: true
                        isTransparent: true
                        text: qpVolumeRow.showSlider ? "" : "-"
                        iconSource: qpVolumeRow.showSlider
                            ? "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ff3333' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5'></polygon><line x1='23' y1='9' x2='17' y2='15'></line><line x1='17' y1='9' x2='23' y2='15'></line></svg>"
                            : ""
                        opacity: (!qpVolumeRow.showSlider && root.volume <= 0.001) ? 0.4 : 1
                        onClicked: {
                            if (qpVolumeRow.showSlider) {
                                if (root.volume > 0)
                                    volumeControl.setVolume(0);
                                else
                                    qpVolumeRow.restoreVolume();
                            } else {
                                volumeControl.stepVolume(-1);
                            }
                        }
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: hovered
                        ToolTip.text: qpVolumeRow.showSlider ? (root.volume > 0 ? qsTr("LNG_00106") : qsTr("LNG_00157")) : qsTr("Lower the volume")
                    }

                    Slider {
                        id: qpVolumeSlider
                        width: qpVolumeRow.showSlider ? 72 : 0
                        height: 24
                        visible: qpVolumeRow.showSlider
                        padding: 0
                        from: 0.0
                        to: 1.0
                        value: root.volume
                        focusPolicy: Qt.NoFocus
                        onMoved: volumeControl.setVolume(value)

                        background: Rectangle {
                            x: qpVolumeSlider.leftPadding
                            y: qpVolumeSlider.topPadding + qpVolumeSlider.availableHeight / 2 - height / 2
                            width: qpVolumeSlider.availableWidth
                            height: 4
                            radius: 2
                            color: "#1c242c"

                            Rectangle {
                                width: qpVolumeSlider.visualPosition * parent.width
                                height: parent.height
                                color: "#00f5d4"
                                radius: 2
                            }
                        }

                        handle: Rectangle {
                            x: qpVolumeSlider.leftPadding + qpVolumeSlider.visualPosition * (qpVolumeSlider.availableWidth - width)
                            y: qpVolumeSlider.topPadding + qpVolumeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 12
                            implicitHeight: 12
                            radius: 6
                            color: qpVolumeSlider.pressed ? "#ff9a00" : "#ff7a00"
                            border.color: "#ffffff"
                            border.width: 1
                        }
                    }

                    CctvButton {
                        focusPolicy: Qt.NoFocus
                        isMini: true
                        isTransparent: true
                        text: qpVolumeRow.showSlider ? "" : "+"
                        iconSource: qpVolumeRow.showSlider
                            ? "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5'></polygon><path d='M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07'></path></svg>"
                            : ""
                        opacity: (!qpVolumeRow.showSlider && root.volume >= 0.999) ? 0.4 : 1
                        onClicked: {
                            if (qpVolumeRow.showSlider)
                                volumeControl.setVolume(1);
                            else
                                volumeControl.stepVolume(1);
                        }
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.visible: hovered
                        ToolTip.text: qpVolumeRow.showSlider ? qsTr("LNG_00157") : qsTr("Raise the volume")
                    }
                }

                CctvButton {
                    id: qpPrevEventBtn
                    focusPolicy: Qt.NoFocus
                    isMini: true
                    isTransparent: true
                    enabled: root.quickPlaybackEvents.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    iconSource: {
                        var colorStr = qpPrevEventBtn.hovered ? "%23ff3344" : "%23ff6677";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='5' y1='5' x2='5' y2='19'></line><polygon points='19 4 9 12 19 20 19 4'></polygon></svg>";
                    }
                    onClicked: root.jumpQuickPlaybackEvent(-1)
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Previous Event")
                }

                CctvButton {
                    id: qpFrameStepBtn
                    focusPolicy: Qt.NoFocus
                    isMini: true
                    isTransparent: true
                    iconSource: {
                        var colorStr = qpFrameStepBtn.hovered ? "%2300f5d4" : "%23ffffff";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='3' y='5' width='12' height='14' rx='1'></rect><polygon points='17 8 22 12 17 16' fill='" + colorStr + "' stroke='none'></polygon></svg>";
                    }
                    onClicked: root.stepQuickPlaybackFrame()
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Next frame")
                }

                CctvButton {
                    id: qpNextEventBtn
                    focusPolicy: Qt.NoFocus
                    isMini: true
                    isTransparent: true
                    enabled: root.quickPlaybackEvents.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    iconSource: {
                        var colorStr = qpNextEventBtn.hovered ? "%23ff3344" : "%23ff6677";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polygon points='5 4 15 12 5 20 5 4'></polygon><line x1='19' y1='5' x2='19' y2='19'></line></svg>";
                    }
                    onClicked: root.jumpQuickPlaybackEvent(1)
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Next Event")
                }

                CctvButton {
                    id: qpPlayPauseBtn
                    focusPolicy: Qt.NoFocus
                    isMini: true
                    isTransparent: true
                    iconSource: {
                        var colorStr = "%23ffffff";
                        if (root.isQuickPlaybackPaused) {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='" + colorStr + "' stroke='none'><polygon points='8 5 19 12 8 19 8 5'></polygon></svg>";
                        } else {
                            return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='" + colorStr + "' stroke='none'><rect x='6' y='4' width='4' height='16' rx='1'></rect><rect x='14' y='4' width='4' height='16' rx='1'></rect></svg>";
                        }
                    }
                    onClicked: {
                        root.isQuickPlaybackPaused = !root.isQuickPlaybackPaused;
                        if (root.isQuickPlaybackPaused) {
                            if (quickPlaybackPlayerLoader.item) {
                                quickPlaybackPlayerLoader.item.pause();
                            }
                        } else {
                            if (quickPlaybackPlayerLoader.item) {
                                quickPlaybackPlayerLoader.item.resume();
                            }
                        }
                    }
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: root.isQuickPlaybackPaused ? qsTr("LNG_00128") : qsTr("LNG_00129")
                }

                CctvButton {
                    id: qpSpeedBtn
                    focusPolicy: Qt.NoFocus
                    text: root.quickPlaybackSpeed + "x"
                    isMini: true
                    isTransparent: true
                    onClicked: {
                        if (root.quickPlaybackSpeed === 1) root.quickPlaybackSpeed = 2;
                        else if (root.quickPlaybackSpeed === 2) root.quickPlaybackSpeed = 4;
                        else root.quickPlaybackSpeed = 1;
                        if (quickPlaybackPlayerLoader.item) {
                            quickPlaybackPlayerLoader.item.setPlaybackSpeed(root.quickPlaybackSpeed);
                        }
                    }
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("LNG_00188")
                }

                CctvButton {
                    id: qpCloseBtn
                    focusPolicy: Qt.NoFocus
                    isMini: true
                    isTransparent: true
                    iconSource: {
                        var colorStr = qpCloseBtn.hovered ? "%23ff3333" : "%238898a6";
                        return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='18' y1='6' x2='6' y2='18'></line><line x1='6' y1='6' x2='18' y2='18'></line></svg>";
                    }
                    onClicked: {
                        root.isQuickPlayback = false;
                    }
                    ToolTip.delay: Compact.toolTipDelay
                    ToolTip.timeout: Compact.toolTipTimeout
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("LNG_00187")
                }
            }
        }

        Timer {
            id: quickPlaybackTimer
            interval: 1000
            repeat: true
            onTriggered: {
                if (root.isQuickPlayback && !root.isQuickPlaybackPaused) {
                    var nextOffset = root.quickPlaybackOffset + root.quickPlaybackSpeed;
                    if (nextOffset > 1800) {
                        nextOffset = 1800;
                        root.isQuickPlaybackPaused = true;
                        if (quickPlaybackPlayerLoader.item) {
                            quickPlaybackPlayerLoader.item.pause();
                        }
                    }
                    root.quickPlaybackOffset = nextOffset;
                }
            }
        }
    }

    // Jump the quick playback position by deltaSeconds (negative = rewind),
    // clamped to the 30 minute window (0 = oldest, 1800 = now).
    function seekQuickPlayback(deltaSeconds) {
        if (!isQuickPlayback || !quickPlaybackActivationTime) return;
        var target = Math.max(0, Math.min(1800, quickPlaybackOffset + deltaSeconds));
        quickPlaybackOffset = target;
        var item = quickPlaybackPlayerLoader.item;
        if (!item) return;
        var seekTime = new Date(quickPlaybackActivationTime.getTime() - (1800 - target) * 1000);
        item.playAtTime(seekTime);
        if (quickPlaybackSpeed !== 1) {
            item.setPlaybackSpeed(quickPlaybackSpeed);
        }
        if (target >= 1800) {
            isQuickPlaybackPaused = true;
            item.pause();
        } else if (!isQuickPlaybackPaused) {
            item.resume();
        }
    }

    // Jump to the previous (direction < 0) or next (direction > 0) event inside
    // the 30 minute quick playback window.
    function jumpQuickPlaybackEvent(direction) {
        if (!isQuickPlayback || !quickPlaybackActivationTime) return;
        var windowEnd = quickPlaybackActivationTime.getTime();
        var windowStart = windowEnd - 1800000;
        var currentMs = windowEnd - (1800 - quickPlaybackOffset) * 1000;
        var targetMs = -1;
        for (var i = 0; i < quickPlaybackEvents.length; i++) {
            var ev = quickPlaybackEvents[i];
            if (!ev) continue;
            var evMs = Math.max(windowStart, ev.startTime);
            if (evMs > windowEnd) continue;
            if (direction > 0 && evMs > currentMs + 1000 && (targetMs < 0 || evMs < targetMs))
                targetMs = evMs;
            else if (direction < 0 && evMs < currentMs - 1000 && (targetMs < 0 || evMs > targetMs))
                targetMs = evMs;
        }
        if (targetMs < 0) return;
        seekQuickPlayback(Math.round((targetMs - currentMs) / 1000));
    }

    // Pause and advance the quick playback by a single frame.
    function stepQuickPlaybackFrame() {
        var item = quickPlaybackPlayerLoader.item;
        if (!isQuickPlayback || !item) return;
        isQuickPlaybackPaused = true;
        item.stepFrame();
    }

    function play() {
        if (activePlayerIndex === 1) qmlAvPlayer1.play();
        else qmlAvPlayer2.play();
    }

    function reload() {
        if (activeStreamUrl !== "" && !root.isQuickPlayback) {
            console.log("[Player] Manual reload triggered for: " + activeCameraId);
            var activePlayer = activePlayerIndex === 1 ? qmlAvPlayer1 : qmlAvPlayer2;
            activePlayer.source = "";
            activePlayer.source = activeStreamUrl;
            activePlayer.play();
        }
    }
//    function pause() { mediaPlayer.pause(); }
//    function seek(position) { mediaPlayer.seek(position); }
    function stop() {
        qmlAvPlayer1.source = "";
        qmlAvPlayer1.isSubStreamOfPlayer = false;
        qmlAvPlayer2.source = "";
        qmlAvPlayer2.isSubStreamOfPlayer = false;
        activeStreamUrl = "";
        activeCameraId = "";
        seamlessSwitchTimer.stop();
    }

    function parseUri(uri) {
        var s = String(uri).trim();
        if (s.indexOf("hikvision://") !== -1) {
            parseHikvisionUri(uri);
        } else if (s.indexOf("rtsp://") !== -1) {
            parseRtspUri(uri);
        }
    }

    function parseRtspUri(uri) {
        var s = String(uri).trim();
        var idx = s.indexOf("rtsp://");
        if (idx === -1) return;

        var content = s.substring(idx + 7); // after "rtsp://"

        // Split at "/" for path
        var slashIdx = content.indexOf("/");
        var mainPart = (slashIdx !== -1) ? content.substring(0, slashIdx) : content;
        var pathPart = (slashIdx !== -1) ? content.substring(slashIdx + 1) : "";

        if (pathPart.length > 0) {
            // Find channel ID from path, e.g. "Streaming/Channels/401"
            var channelMatch = pathPart.match(/(\d+)/);
            if (channelMatch) {
                var chanNum = parseInt(channelMatch[1]);
                if (chanNum >= 100) {
                    channelId = Math.floor(chanNum / 100);
                } else {
                    channelId = chanNum;
                }
            } else {
                channelId = 1;
            }
        }

        // Split at "@" for credentials and address (find LAST '@' in mainPart)
        var atIdx = mainPart.lastIndexOf("@");
        var addrPort = "";
        if (atIdx !== -1) {
            var credsPart = mainPart.substring(0, atIdx);
            addrPort = mainPart.substring(atIdx + 1);
            var colonIdx = credsPart.indexOf(":");
            if (colonIdx !== -1) {
                username = decodeURIComponent(credsPart.substring(0, colonIdx));
                password = decodeURIComponent(credsPart.substring(colonIdx + 1));
            } else {
                username = decodeURIComponent(credsPart);
                password = "";
            }
        } else {
            addrPort = mainPart;
            username = "";
            password = "";
        }

        // Split at ":" for ip and port
        var ipPort = addrPort.split(":");
        recorderIp = (ipPort[0] || "").trim();
        var explicitPort = (ipPort.length > 1) ? parseInt(ipPort[1]) : 0;

        // Resolve SDK, HTTP, RTSP ports by searching in configured recorders
        sdkPort = 8000;
        recorderPort = 8000;
        httpPort = 80;
        rtspPort = explicitPort > 0 ? explicitPort : 554;
        try {
            var jsonStr = rootWindow.hikvisionRecordersJson;
            if (jsonStr) {
                var recordersList = JSON.parse(jsonStr);
                for (var i = 0; i < recordersList.length; ++i) {
                    var rec = recordersList[i];
                    var recIp = (rec.ip || "").trim();
                    var cleanRecIp = recIp.split(":")[0];
                    if (recIp === recorderIp || cleanRecIp === recorderIp) {
                        sdkPort = parseInt(rec.sdkPort || rec.port) || 8000;
                        recorderPort = sdkPort;
                        httpPort = parseInt(rec.httpPort || (rec.port == 8000 ? 80 : rec.port)) || 80;
                        rtspPort = parseInt(rec.rtspPort) || explicitPort || 554;
                        rtspTransport = rec.rtspTransport || "";
                        if (!username && rec.username) username = rec.username;
                        if (!password && rec.password) password = rec.password;
                        break;
                    }
                }
            }
        } catch (e) {
            console.log("[Player QML Error] Failed to resolve recorder ports from JSON:", e);
        }
    }

    function parseHikvisionUri(uri) {
        var s = String(uri).trim();
        var idx = s.indexOf("hikvision://");
        if (idx === -1) return;
        
        var content = s.substring(idx + 12); // after "hikvision://"
        
        // Split at "/" for channel
        var slashIdx = content.indexOf("/");
        var mainPart = (slashIdx !== -1) ? content.substring(0, slashIdx) : content;
        var pathPart = (slashIdx !== -1) ? content.substring(slashIdx + 1) : "";

        if (pathPart.length > 0) {
            channelId = parseInt(pathPart) || 1;
        }
        
        // Split at "@" for credentials and address
        var atIdx = mainPart.lastIndexOf("@");
        var addrPort = "";
        if (atIdx !== -1) {
            var credsPart = mainPart.substring(0, atIdx);
            addrPort = mainPart.substring(atIdx + 1);
            var colonIdx = credsPart.indexOf(":");
            if (colonIdx !== -1) {
                username = decodeURIComponent(credsPart.substring(0, colonIdx));
                password = decodeURIComponent(credsPart.substring(colonIdx + 1));
            } else {
                username = decodeURIComponent(credsPart);
                password = "";
            }
        } else {
            addrPort = mainPart;
            username = "";
            password = "";
        }
        
        // Split at ":" for ip and port
        var ipPort = addrPort.split(":");
        recorderIp = (ipPort[0] || "").trim();
        var explicitPort = (ipPort.length > 1) ? parseInt(ipPort[1]) : 0;

        // Resolve all ports from JSON
        sdkPort = explicitPort > 0 ? explicitPort : 8000;
        recorderPort = sdkPort;
        httpPort = 80;
        rtspPort = 554;
        try {
            var jsonStr2 = rootWindow.hikvisionRecordersJson;
            if (jsonStr2) {
                var recordersList2 = JSON.parse(jsonStr2);
                for (var j = 0; j < recordersList2.length; ++j) {
                    var rec2 = recordersList2[j];
                    var recIp2 = (rec2.ip || "").trim();
                    var cleanRecIp2 = recIp2.split(":")[0];
                    if (recIp2 === recorderIp || cleanRecIp2 === recorderIp) {
                        sdkPort = parseInt(rec2.sdkPort || rec2.port) || explicitPort || 8000;
                        recorderPort = sdkPort;
                        httpPort = parseInt(rec2.httpPort || (rec2.port == 8000 ? 80 : rec2.port)) || 80;
                        rtspPort = parseInt(rec2.rtspPort) || 554;
                        rtspTransport = rec2.rtspTransport || "";
                        if (!username && rec2.username) username = rec2.username;
                        if (!password && rec2.password) password = rec2.password;
                        break;
                    }
                }
            }
        } catch (e2) {
            console.log("[Player QML Error] Failed to resolve recorder ports from JSON:", e2);
        }
    }

    Connections {
        target: (typeof rootWindow !== "undefined") ? rootWindow : null
        function onHikvisionRecordersJsonChanged() {
            if (root.isHikvision) {
                updateSource();
            }
        }
    }

    // Shown instead of video while the tile's recorder is set offline (see the recorder monitoring window).
    Rectangle {
        anchors.fill: parent
        visible: root.recorderOffline
        color: "#10161c"
        z: 50
        Text {
            anchors.centerIn: parent
            width: parent.width - 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#8898a6"
            font.pixelSize: Math.max(10, Math.min(16, parent.width / 14))
            text: "Offline by choice\n" + root.recorderIp
        }
    }

    SnapshotSavedDialog {
        id: localSnapshotSavedDialog
}
    }
