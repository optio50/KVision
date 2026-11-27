import QtQml 2.11
import QtQuick 2.11
import QtQuick.Layouts 1.11
import QtQuick.Controls 2.4
import Qt.labs.settings 1.0
import QtGraphicalEffects 1.0
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Themes 1.0
import "qrc:/Compact"
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Hikvision 1.0
import Qt.labs.platform 1.1 as Platform
import QtQuick.Dialogs 1.3 as QuickDialogs

FocusScope {
    id: rootSideBar

    enum State {
        Compact,
        Popup,
        Expanded
    }

    anchors.fill: parent
    implicitWidth: 800
    implicitHeight: 600

    property int state: SideBar.Expanded
    property int currentViewportIndex: Utils.currentLayout() ? Utils.currentLayout().focusIndex : -1

    onVisibleChanged: {
        resetPathChangesCheckbox();
    }

    function resetPathChangesCheckbox() {
        if (typeof activatePathChangesCheckbox !== "undefined" && activatePathChangesCheckbox) {
            activatePathChangesCheckbox.checked = false;
        }
        if (typeof activateMediaChangesCheckbox !== "undefined" && activateMediaChangesCheckbox) {
            activateMediaChangesCheckbox.checked = false;
        }
    }

    // How many deleted layouts still have backups (for the "Recover a deleted layout" button)
    property int deletedBackupCount: 0
    // Worked out again a moment after the layouts change (they are loaded after this screen is created, and each change
    // would otherwise read every backup file)
    Timer {
        id: deletedBackupsTimer
        interval: 800
        repeat: false
        onTriggered: rootSideBar.refreshDeletedBackups()
    }
    function refreshDeletedBackups() {
        var live = [];
        for (var i = 0; i < layoutsCollectionModel.count; ++i) {
            var l = layoutsCollectionModel.get(i);
            if (l && l.uid)
                live.push(l.uid);
        }
        deletedBackupCount = LayoutBackups.deletedLayouts(live).length;
    }

    function auxiliaryScaleIndex() {
        var s = String(generalSettings.auxiliaryScale);
        if (s === "same") return 0;
        if (s === "1.5") return 2;
        if (s === "2") return 3;
        return 1;
    }

    function layoutHasCameras(l) {
        if (!l)
            return false;
        for (var i = 0; i < l.count; ++i) {
            var it = l.get(i);
            if (it && it.url !== "")
                return true;
        }
        return false;
    }

    // The trash button. A layout that has backups asks what to do with them; one that has none but has cameras gets a last
    // copy saved first, so deleting it by mistake can be undone ("Recover a deleted layout").
    function deleteLayoutAt(index) {
        var l = layoutsCollectionModel.get(index);
        if (!l)
            return;
        if (LayoutBackups.count(l.uid) > 0) {
            keepBackupsDialog.index = index;
            keepBackupsDialog.open();
            return;
        }
        finishDelete(index, "keep");
    }

    // what: "keep" saves a last copy and keeps every backup, "delete" removes the backups too.
    function finishDelete(index, what) {
        var l = layoutsCollectionModel.get(index);
        if (!l)
            return;
        var uid = l.uid;
        if (what === "delete") {
            LayoutBackups.removeAll(uid);
        } else if (layoutHasCameras(l)) {
            LayoutBackups.save(uid, JSON.stringify(layoutsCollectionModel.toJSValue()[index]), qsTr("Deleted"), true);
        }
        layoutsCollectionModel.remove(index);
        refreshDeletedBackups();
    }

    property var savedLayoutIndices: []
    property int selectedLayoutIndex: -1

    property bool hasNewVersion: false
    property string newVersionString: ""

    function parseVersion(vStr) {
        var clean = vStr.replace(/^v/, "");
        var match = clean.match(/^(\d+(?:\.\d+)*)(?:-(\d+))?/);
        if (!match) {
            return { base: [0], rel: 0 };
        }
        var baseParts = match[1].split(".").map(Number);
        var rel = match[2] ? Number(match[2]) : 0;
        return { base: baseParts, rel: rel };
    }

    function compareVersions(v1, v2) {
        var parsed1 = parseVersion(v1);
        var parsed2 = parseVersion(v2);
        var len = Math.max(parsed1.base.length, parsed2.base.length);
        for (var i = 0; i < len; ++i) {
            var p1 = parsed1.base[i] || 0;
            var p2 = parsed2.base[i] || 0;
            if (p1 !== p2) {
                return p1 - p2;
            }
        }
        return parsed1.rel - parsed2.rel;
    }

    function checkForUpdates() {
        if (Context.mockNewVersion) {
            hasNewVersion = true;
            newVersionString = "v9.9.9 (MOCK)";
            return;
        }
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "https://api.github.com/repos/optio50/KVision/releases/latest", true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        var response = JSON.parse(xhr.responseText);
                        var latestVersion = response.tag_name;
                        var currentVersion = Qt.application.version;
                        
                        if (compareVersions(latestVersion, currentVersion) > 0) {
                            hasNewVersion = true;
                            newVersionString = latestVersion;
                        } else {
                            hasNewVersion = false;
                        }
                    } catch (e) {
                        console.error("Failed to parse update check response:", e);
                    }
                }
            }
        }
        xhr.send();
    }

    function updateIndices() {
        var saved = [];
        var scratch = (typeof rootWindow !== "undefined" && rootWindow) ? rootWindow.scratchLayout : null;
        for (var i = 0; i < layoutsCollectionModel.count; ++i) {
            var layout = layoutsCollectionModel.get(i);
            if (!layout || layout === scratch)
                continue;
            saved.push(i);
        }
        savedLayoutIndices = saved;
        var stillThere = false;
        for (var s = 0; s < saved.length; ++s) {
            if (saved[s] === selectedLayoutIndex) {
                stillThere = true;
                break;
            }
        }
        if (!stillThere) {
            var pick = -1;
            for (var t = 0; t < saved.length; ++t) {
                if (saved[t] === stackLayout.currentIndex) {
                    pick = stackLayout.currentIndex;
                    break;
                }
            }
            if (pick < 0 && saved.length > 0)
                pick = saved[0];
            selectedLayoutIndex = pick;
        }
    }

    function savedLayoutPosition(collectionIndex) {
        var saved = savedLayoutIndices;
        for (var i = 0; i < saved.length; ++i) {
            if (saved[i] === collectionIndex)
                return i;
        }
        return -1;
    }

    function canMoveSavedLayout(fromIndex, direction) {
        var pos = savedLayoutPosition(fromIndex);
        if (pos < 0)
            return false;
        var destPos = pos + direction;
        return destPos >= 0 && destPos < savedLayoutIndices.length;
    }

    // direction -1 moves the selected layout toward the top of the list, +1 toward the bottom.
    // The toolbar buttons walk this same list.
    function moveSavedLayout(fromIndex, direction) {
        if (!canMoveSavedLayout(fromIndex, direction))
            return;
        var destPos = savedLayoutPosition(fromIndex) + direction;
        var moving = layoutsCollectionModel.get(fromIndex);
        var toIndex = savedLayoutIndices[destPos];
        rootWindow.moveLayoutKeepingView(fromIndex, toIndex);
        for (var j = 0; j < layoutsCollectionModel.count; ++j) {
            if (layoutsCollectionModel.get(j) === moving) {
                selectedLayoutIndex = j;
                break;
            }
        }
    }

    Component.onCompleted: {
        layoutsCollectionModel.changed.connect(updateIndices);
        layoutsCollectionModel.changed.connect(function () { deletedBackupsTimer.restart(); });
        updateIndices();
        deletedBackupsTimer.restart();
        resetPathChangesCheckbox();
        checkForUpdates();
    }

    // Adds or removes one key in a comma-separated setting, keeping the others.
    function toggledList(list, key, on) {
        var items = list === "" ? [] : list.split(",");
        var at = items.indexOf(key);
        if (on && at < 0)
            items.push(key);
        else if (!on && at >= 0)
            items.splice(at, 1);
        return items.join(",");
    }

    property var changelogData: [
        {
            version: "v3.9.0",
            date: "22 Nov 2026",
            changes: [
                qsTr("Add Stream saves an RTSP, HTTP or HTTPS address, including an HLS playlist, as a one-channel camera."),
                qsTr("VCA target boxes and rule lines are drawn on the live tile from the camera's smart data, on the main stream and the sub-stream, including panoramic and G3 cameras. Playback can draw the recorded lines and boxes."),
                qsTr("Camera settings names the targets of each detection rule, reads both lenses of a two-lens camera, and stops an All cameras read when the window closes.")
            ]
        },
        {
            version: "v3.8.0",
            date: "19 Nov 2026",
            changes: [
                qsTr("Smart search in playback: search one camera or every camera on a recorder, using detection-event pictures and recorder face search, and open playback at a result."),
                qsTr("Camera settings now shows H.265+ and H.264+, and Camera Tools can read and set each stream's maximum bitrate."),
                qsTr("Camera status readings, 3D positioning for PTZ cameras, network device scanning, face detection reports, and more camera Quick tools."),
                qsTr("Camera clock and firmware checks, with a firmware reference saved for each model."),
                qsTr("Presets can be reordered, layouts are unified, and archive playback can pause live pictures.")
            ]
        },
        {
            version: "v3.7.0",
            date: "14 Nov 2026",
            changes: [
                qsTr("Quick tools in the camera right-click menu, including camera rule lines, plus Camera Tools controls for checking and changing rule lines on every camera."),
                qsTr("MQTT overlay text supports several cameras and topics, with a choice of what happens when KVision closes."),
                qsTr("Event pictures can be zoomed and panned, and snapshots can save either the full image or the zoomed view."),
                qsTr("Layout Backup / Restore, automatic daily backups, recovery of deleted layouts, and a way to apply another layout's grid."),
                qsTr("Per-camera detection report sources, optional unlabelled motion logging, a browser choice, and settings organized into sections.")
            ]
        },
        {
            version: "v3.6.0",
            date: "12 Nov 2026",
            changes: [
                qsTr("Read-only Camera settings window for one camera or all cameras, covering device, video, image, detection, schedules, storage and users."),
                qsTr("Camera configuration backup and restore, with safety checks and a fresh backup before restoring."),
                qsTr("Detection logging can continue after KVision closes through the background detection service."),
                qsTr("Detection events shows which entries are older than the recorder's available video, and unknown event types are kept in OtherEvents.log."),
                qsTr("Statistics history and stream counters, plus working CPU and AMD/Intel GPU readings.")
            ]
        },
        {
            version: "v3.5.0",
            date: "12 Nov 2026",
            changes: [
                qsTr("Overlay text from MQTT: show a value from an MQTT broker (an outside temperature, for instance) in a camera's on-screen text, refreshed every few minutes, in Celsius or Fahrenheit. Off by default."),
                qsTr("Detection events window: search by time range, target and type across all cameras, with a count, and save the picture you are looking at as a snapshot."),
                qsTr("Event pictures that have no camera frame get a target box and the zone drawn on them (with a tick box to hide them), and the caption shows the zone."),
                qsTr("Playback: 5-second rewind and forward buttons. A PTZ track keeps four snapshots, the first taken at once."),
                qsTr("The tooltip binding-loop warning is hidden unless KVision is started with --verbose.")
            ]
        },
        {
            version: "v3.4.0",
            date: "11 Nov 2026",
            changes: [
                qsTr("Two-lens PTZ cameras: each lens is logged and shown as its own camera, with its own pictures. A PTZ that follows a target shows an amber TRACKING frame, and a Tracking entry keeps two snapshots a second apart."),
                qsTr("Detection events window (was Detection log): the picture viewer steps through every picture in the list, with Right going to the next newest."),
                qsTr("Playback timelines colour events by kind (motion, line, intrusion, entrance, exit) and also show events from the detection log, where the recording has video."),
                qsTr("Event pictures keep a separate file for each kind of event in the same second."),
                qsTr("The detection frame can be switched on or off for every camera in one window, and event pictures are kept per camera (100, 500 or 1000).")
            ]
        },
        {
            version: "v3.3.0",
            date: "11 Nov 2026",
            changes: [
                qsTr("Choose where cameras behind a recorder get their detection reports: each camera directly, or through the recorder (one connection, human, vehicle and animal labels and the event type with the channel number)."),
                qsTr("Choose which event types (motion, line crossing, intrusion, region entrance, region exit, other) and which targets (human, vehicle, animal, other) show a frame. The detection log keeps every report."),
                qsTr("Check detection setup: a read-only check of each camera and recorder (metadata, zones, rules, Notify Surveillance Center, where a rule lives). Right-click a camera or use the sidebar buttons."),
                qsTr("Event pictures are saved, shown in the detection log window, and kept per camera (100, 500 or 1000 in the settings)."),
                qsTr("One window with a tick box for every camera to switch the detection frame on or off, with All on and All off."),
                qsTr("Fixed line crossings and intrusions missed on camera streams that attach a picture, and streams that die are reopened. The frame label no longer changes to plain motion right after a line or intrusion report.")
            ]
        },
        {
            version: "v3.2.0",
            date: "10 Nov 2026",
            changes: [
                qsTr("On-screen event detection: a tile shows a frame and a caption such as HUMAN - LINE when its camera reports a human, vehicle or animal. Works for standalone cameras and cameras behind an NVR."),
                qsTr("Reads labelled motion, line crossing, intrusion, region entrance and region exit. It depends on the detection settings inside each camera being set up correctly."),
                qsTr("Detection log: every report is written to logs/Detection.log. Right-click a tile and choose Detection events to browse it, and double-click an entry to open playback just before the event.")
            ]
        },
        {
            version: "v3.1.0",
            date: "9 Nov 2026",
            changes: [
                qsTr("Hold-to-talk two-way audio: hold the microphone badge on a live Hikvision tile to speak through the camera speaker. Works for standalone cameras and cameras behind an NVR."),
                qsTr("Follows the audio format each camera asks for: G.711 u-law, G.711 A-law or AAC (older doorbells)."),
                qsTr("Settings for the talk microphone, microphone gain, output boost and an off switch. Right-click the badge to set the camera speaker volume.")
            ]
        },
        {
            version: "v3.0.0",
            date: "9 Nov 2026",
            changes: [
                qsTr("Independent Linux-only fork of KVision 2.7.5. Windows, packaging recipes and extra languages removed."),
                qsTr("Live view: mouse PTZ with double-digit presets and focus, drag-and-swap cells, right-click camera picker, wheel zoom, third Hikvision stream, 18x18 grid."),
                qsTr("Playback: NVR smart events on the timeline, event and frame stepping, 6x speed, timeline range download, SD-card playback fallback."),
                qsTr("Snapshots are named with the camera/NVR time of the frame shown, not the PC clock.")
            ]
        },
        {
            version: "v2.7.5",
            date: "29 Oct 2026",
            changes: [
                qsTr("LNG_00568")
            ]
        },
        {
            version: "v2.7.4",
            date: "29 Oct 2026",
            changes: [
                qsTr("LNG_00565"),
                qsTr("LNG_00566"),
                qsTr("LNG_00567")
            ]
        },
        {
            version: "v2.7.3",
            date: "28 Oct 2026",
            changes: [
                qsTr("LNG_00564")
            ]
        },
        {
            version: "v2.7.2",
            date: "27 Oct 2026",
            changes: [
                qsTr("LNG_00547"),
                qsTr("LNG_00548"),
                qsTr("LNG_00550")
            ]
        },
        {
            version: "v2.7.1-rc5",
            date: "27 Aug 2026",
            changes: [
                qsTr("LNG_00544"),
                qsTr("LNG_00545")
            ]
        },
        {
            version: "v2.7.1-rc4",
            date: "7 Aug 2026",
            changes: [
                qsTr("LNG_00542")
            ]
        },
        {
            version: "v2.7.1-rc3",
            date: "7 Aug 2026",
            changes: [
                qsTr("LNG_00540"),
                qsTr("LNG_00541")
            ]
        },
        {
            version: "v2.7.1-rc2",
            date: "7 Aug 2026",
            changes: [
                qsTr("LNG_00543")
            ]
        },
        {
            version: "v2.7.1-rc1",
            date: "4 Aug 2026",
            changes: [
                qsTr("LNG_00538"),
                qsTr("LNG_00539")
            ]
        },
        {
            version: "v2.7.0",
            date: "27 Jul 2026",
            changes: [
                qsTr("LNG_00535"),
                qsTr("LNG_00536"),
                qsTr("LNG_00537")
            ]
        },
        {
            version: "v2.6.3",
            date: "8 Jul 2026",
            changes: [
                qsTr("LNG_00546")
            ]
        },
        {
            version: "v2.6.2",
            date: "8 Jul 2026",
            changes: [
                qsTr("LNG_00527"),
                qsTr("LNG_00528"),
                qsTr("LNG_00531")
            ]
        },
        {
            version: "v2.6.1",
            date: "7 Jul 2026",
            changes: [
                qsTr("LNG_00529"),
                qsTr("LNG_00530")
            ]
        },
        {
            version: "v2.6.0",
            date: "3 Jul 2026",
            changes: [
                qsTr("LNG_00517"),
                qsTr("LNG_00518")
            ]
        },
        {
            version: "v2.5.0",
            date: "3 Jul 2026",
            changes: [
                qsTr("LNG_00519"),
                qsTr("LNG_00520"),
                qsTr("LNG_00521"),
                qsTr("LNG_00522"),
                qsTr("LNG_00523"),
                qsTr("LNG_00524"),
                qsTr("LNG_00525"),
                qsTr("LNG_00526")
            ]
        },
        {
            version: "v2.4.6",
            date: "2 Jul 2026",
            changes: [
                qsTr("LNG_00452"),
                qsTr("LNG_00451")
            ]
        },
        {
            version: "v2.4.5",
            date: "2 Jul 2026",
            changes: [
                qsTr("LNG_00450"),
                qsTr("LNG_00449"),
                qsTr("LNG_00448"),
                qsTr("LNG_00447"),
                qsTr("LNG_00446")
            ]
        },
        {
            version: "v2.4.4",
            date: "2 Jul 2026",
            changes: [
                qsTr("LNG_00445")
            ]
        },
        {
            version: "v2.4.3",
            date: "1 Jul 2026",
            changes: [
                qsTr("LNG_00444"),
                qsTr("LNG_00443")
            ]
        },
        {
            version: "v2.4.2",
            date: "1 Jul 2026",
            changes: [
                qsTr("LNG_00442"),
                qsTr("LNG_00441")
            ]
        },
        {
            version: "v2.4.1",
            date: "1 Jul 2026",
            changes: [
                qsTr("LNG_00440"),
                qsTr("LNG_00439"),
                qsTr("LNG_00438"),
                qsTr("LNG_00437")
            ]
        },
        {
            version: "v2.4.0",
            date: "30 Jun 2026",
            changes: [
                qsTr("LNG_00436")
            ]
        },
        {
            version: "v2.3.0",
            date: "30 Jun 2026",
            changes: [
                qsTr("LNG_00435"),
                qsTr("LNG_00434"),
                qsTr("LNG_00433"),
                qsTr("LNG_00432"),
                qsTr("LNG_00431"),
                qsTr("LNG_00430"),
                qsTr("LNG_00429")
            ]
        },
        {
            version: "v2.2.8-2",
            date: "29 Jun 2026",
            changes: [
                qsTr("LNG_00428"),
                qsTr("LNG_00427")
            ]
        },
        {
            version: "v2.2.8-1",
            date: "29 Jun 2026",
            changes: [
                qsTr("LNG_00426"),
                qsTr("LNG_00425"),
                qsTr("LNG_00424"),
                qsTr("LNG_00423"),
                qsTr("LNG_00422"),
                qsTr("LNG_00421"),
                qsTr("LNG_00420"),
                qsTr("LNG_00419")
            ]
        },
        {
            version: "v2.2.7-5",
            date: "29 Jun 2026",
            changes: [
                qsTr("LNG_00418")
            ]
        },
        {
            version: "v2.2.7-4",
            date: "29 Jun 2026",
            changes: [
                qsTr("LNG_00417")
            ]
        },
        {
            version: "v2.2.7-3",
            date: "29 Jun 2026",
            changes: [
                qsTr("LNG_00416"),
                qsTr("LNG_00415"),
                qsTr("LNG_00414"),
                qsTr("LNG_00413"),
                qsTr("LNG_00412"),
                qsTr("LNG_00411"),
                qsTr("LNG_00410"),
                qsTr("LNG_00409"),
                qsTr("LNG_00408"),
                qsTr("LNG_00407")
            ]
        },
        {
            version: "v2.2.6-3",
            date: "27 Jun 2026",
            changes: [
                qsTr("LNG_00406"),
                qsTr("LNG_00405"),
                qsTr("LNG_00404"),
                qsTr("LNG_00403"),
                qsTr("LNG_00402"),
                qsTr("LNG_00401"),
                qsTr("LNG_00400"),
                qsTr("LNG_00399"),
                qsTr("LNG_00398"),
                qsTr("LNG_00397"),
                qsTr("LNG_00396"),
                qsTr("LNG_00395")
            ]
        },
        {
            version: "v2.2.5",
            date: "25 Jun 2026",
            changes: [
                qsTr("LNG_00394"),
                qsTr("LNG_00393"),
                qsTr("LNG_00392"),
                qsTr("LNG_00391"),
                qsTr("LNG_00390"),
                qsTr("LNG_00389"),
                qsTr("LNG_00388"),
                qsTr("LNG_00387"),
                qsTr("LNG_00386")
            ]
        },
        {
            version: "v2.2.0",
            date: "24 Jun 2026",
            changes: [
                qsTr("LNG_00385"),
                qsTr("LNG_00384"),
                qsTr("LNG_00383"),
                qsTr("LNG_00382"),
                qsTr("LNG_00381")
            ]
        },
        {
            version: "v2.1.9",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00380"),
                qsTr("LNG_00379"),
                qsTr("LNG_00378"),
                qsTr("LNG_00377"),
                qsTr("LNG_00376"),
                qsTr("LNG_00375"),
                qsTr("LNG_00374"),
                qsTr("LNG_00373"),
                qsTr("LNG_00372")
            ]
        },
        {
            version: "v2.1.8",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00371"),
                qsTr("LNG_00370"),
                qsTr("LNG_00369")
            ]
        },
        {
            version: "v2.1.7",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00368")
            ]
        },
        {
            version: "v2.1.6",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00367")
            ]
        },
        {
            version: "v2.1.5",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00366"),
                qsTr("LNG_00365"),
                qsTr("LNG_00364")
            ]
        },
        {
            version: "v2.1.4",
            date: "23 Jun 2026",
            changes: [
                qsTr("LNG_00363"),
                qsTr("LNG_00362"),
                qsTr("LNG_00361"),
                qsTr("LNG_00360")
            ]
        },
        {
            version: "v2.1.3",
            date: "22 Jun 2026",
            changes: [
                qsTr("LNG_00359"),
                qsTr("LNG_00358"),
                qsTr("LNG_00357")
            ]
        },
        {
            version: "v2.1.2",
            date: "19 Jun 2026",
            changes: [
                qsTr("LNG_00356")
            ]
        },
        {
            version: "v2.1.1",
            date: "19 Jun 2026",
            changes: [
                qsTr("LNG_00355"),
                qsTr("LNG_00354"),
                qsTr("LNG_00353")
            ]
        },
        {
            version: "v2.1.0",
            date: "19 Jun 2026",
            changes: [
                qsTr("LNG_00352"),
                qsTr("LNG_00351"),
                qsTr("LNG_00350"),
                qsTr("LNG_00349"),
                qsTr("LNG_00348"),
                qsTr("LNG_00347"),
                qsTr("LNG_00346"),
                qsTr("LNG_00345"),
                qsTr("LNG_00344"),
                qsTr("LNG_00343")
            ]
        },
        {
            version: "v2.0.9-2 (Patch)",
            date: "19 Jun 2026",
            changes: [
                qsTr("LNG_00342"),
                qsTr("LNG_00341")
            ]
        },
        {
            version: "v2.0.9",
            date: "19 Jun 2026",
            changes: [
                qsTr("LNG_00340"),
                qsTr("LNG_00339"),
                qsTr("LNG_00338"),
                qsTr("LNG_00337")
            ]
        },
        {
            version: "v2.0.7-8",
            date: "17 Jun 2026",
            changes: [
                qsTr("LNG_00336"),
                qsTr("LNG_00335")
            ]
        },
        {
            version: "v2.0.6",
            date: "15 Jun 2026",
            changes: [
                qsTr("LNG_00334"),
                qsTr("LNG_00333"),
                qsTr("LNG_00332"),
                qsTr("LNG_00331"),
                qsTr("LNG_00330"),
                qsTr("LNG_00329"),
                qsTr("LNG_00328"),
                qsTr("LNG_00327"),
                qsTr("LNG_00326")
            ]
        },
        {
            version: "v2.0.0",
            date: "5 Jun 2026",
            changes: [
                qsTr("LNG_00325"),
                qsTr("LNG_00324"),
                qsTr("LNG_00323"),
                qsTr("LNG_00322"),
                qsTr("LNG_00321"),
                qsTr("LNG_00320")
            ]
        }
    ]

    Settings {
        id: sideBarSettings
        fileName: Context.config.fileName
        category: "SideBar"
        property string windowDivision
        property string itemsState
    }

    function getRecorderName(ip) {
        try {
            var list = JSON.parse(rootWindow.hikvisionRecordersJson);
            for (var i = 0; i < list.length; ++i) {
                if (list[i].ip === ip) {
                    if (list[i].name && list[i].name.trim() !== "") {
                        return list[i].name;
                    }
                    break;
                }
            }
        } catch(e) {}
        return ip;
    }

    // Split Layout Container
    RowLayout {
        id: splitLayout
        anchors.fill: parent
        spacing: 0

        // Left Navigation Sidebar
        Rectangle {
            id: leftSidebar
            Layout.fillHeight: true
            width: 220
            color: "#0b0f13"

            // Right glow separator
            Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                color: "#2a3540"
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 16

                // Logo/Header area
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    Image {
                        source: "qrc:/images/256.png"
                        Layout.preferredWidth: leftSidebar.width * 2 / 3
                        Layout.preferredHeight: leftSidebar.width * 2 / 3
                        Layout.alignment: Qt.AlignHCenter
                        fillMode: Image.PreserveAspectFit
                    }

                    Text {
                        text: qsTr("LNG_00003")
                        color: "#ffffff"
                        font {
                            pixelSize: 20
                            bold: true
                        }
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth: true
                    }

                    Text {
                        text: qsTr("LNG_00319").arg(Qt.application.version)
                        color: "#00f5d4"
                        font {
                            pixelSize: 12
                            bold: true
                        }
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#2a3540"
                }

                // Page selection buttons
                ColumnLayout {
                    id: tabsColumn
                    Layout.fillWidth: true
                    spacing: 8

                    property int activeIndex: 3

                    function selectTab(index) {
                        activeIndex = index;
                        pagesStack.currentIndex = index;
                        rootSideBar.resetPathChangesCheckbox();
                    }

                    // Viewport Page Button
                    Button {
                        id: btnViewport
                        visible: false
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 0 ? "#1c242c" : (btnViewport.hovered ? "#141a21" : "transparent")
                            radius: 6

                            // Active Glowing border
                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 0
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgViewport
                                    source: "qrc:/images/menu-viewport.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgViewport
                                    source: imgViewport
                                    color: tabsColumn.activeIndex === 0 ? "#00f5d4" : (btnViewport.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00316").arg(rootSideBar.currentViewportIndex >= 0 ? qsTr("LNG_00315").arg(rootSideBar.currentViewportIndex + 1) : "")
                                color: tabsColumn.activeIndex === 0 ? "#00f5d4" : (btnViewport.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 0
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(0)
                    }

                    // Tools Page Button
                    Button {
                        id: btnTools
                        visible: false
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 1 ? "#1c242c" : (btnTools.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 1
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgTools
                                    source: "qrc:/images/menu-tools.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgTools
                                    source: imgTools
                                    color: tabsColumn.activeIndex === 1 ? "#00f5d4" : (btnTools.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00314")
                                color: tabsColumn.activeIndex === 1 ? "#00f5d4" : (btnTools.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 1
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(1)
                    }

                    // Recorders Page Button
                    Button {
                        id: btnRecorders
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 2 ? "#1c242c" : (btnRecorders.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 2
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgRecorders
                                    source: "qrc:/images/menu-recorders.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgRecorders
                                    source: imgRecorders
                                    color: tabsColumn.activeIndex === 2 ? "#00f5d4" : (btnRecorders.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00313")
                                color: tabsColumn.activeIndex === 2 ? "#00f5d4" : (btnRecorders.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 2
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(2)
                    }

                    // Presets Page Button
                    Button {
                        id: btnPresets
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 3 ? "#1c242c" : (btnPresets.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 3
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgPresets
                                    source: "qrc:/images/menu-presets.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgPresets
                                    source: imgPresets
                                    color: tabsColumn.activeIndex === 3 ? "#00f5d4" : (btnPresets.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00312")
                                color: tabsColumn.activeIndex === 3 ? "#00f5d4" : (btnPresets.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 3
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(3)
                    }

                    // General Settings Page Button
                    Button {
                        id: btnSettings
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 4 ? "#1c242c" : (btnSettings.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 4
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgSettings
                                    source: "qrc:/images/menu-settings.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgSettings
                                    source: imgSettings
                                    color: tabsColumn.activeIndex === 4 ? "#00f5d4" : (btnSettings.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00311")
                                color: tabsColumn.activeIndex === 4 ? "#00f5d4" : (btnSettings.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 4
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(4)
                    }

                    // Import / Export Settings Page Button
                    Button {
                        id: btnImportExport
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 5 ? "#1c242c" : (btnImportExport.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 5
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgImportExport
                                    source: "qrc:/images/menu-backup.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgImportExport
                                    source: imgImportExport
                                    color: tabsColumn.activeIndex === 5 ? "#00f5d4" : (btnImportExport.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00551")
                                color: tabsColumn.activeIndex === 5 ? "#00f5d4" : (btnImportExport.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 5
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(5)
                    }

                    // Changelog Page Button
                    Button {
                        id: btnChangelog
                        Layout.fillWidth: true
                        height: 40
                        hoverEnabled: true

                        background: Rectangle {
                            color: tabsColumn.activeIndex === 6 ? "#1c242c" : (btnChangelog.hovered ? "#141a21" : "transparent")
                            radius: 6

                            Rectangle {
                                anchors.left: parent.left
                                width: 3
                                height: parent.height
                                color: "#00f5d4"
                                visible: tabsColumn.activeIndex === 6
                            }
                        }

                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            spacing: 12

                            Item {
                                implicitWidth: 14
                                implicitHeight: 14

                                Image {
                                    id: imgChangelog
                                    source: "qrc:/images/menu-changelog.svg"
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    layer.enabled: true
                                }

                                ColorOverlay {
                                    anchors.fill: imgChangelog
                                    source: imgChangelog
                                    color: tabsColumn.activeIndex === 6 ? "#00f5d4" : (btnChangelog.hovered ? "white" : "#8898a6")
                                    cached: true
                                }
                            }

                            Text {
                                text: qsTr("LNG_00310")
                                color: tabsColumn.activeIndex === 6 ? "#00f5d4" : (btnChangelog.hovered ? "white" : "#8898a6")
                                font {
                                    pixelSize: 12
                                    bold: tabsColumn.activeIndex === 6
                                }
                                Layout.fillWidth: true
                            }
                        }

                        onClicked: tabsColumn.selectTab(6)
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                MouseArea {
                    id: updateArea
                    Layout.fillWidth: true
                    implicitHeight: updateLayout.implicitHeight
                    visible: rootSideBar.hasNewVersion
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: {
                        WebBrowser.open("https://github.com/optio50/KVision/releases/latest")
                    }

                    ColumnLayout {
                        id: updateLayout
                        anchors.fill: parent
                        spacing: 6
                        Layout.alignment: Qt.AlignHCenter

                        Item {
                            implicitWidth: 80
                            implicitHeight: 80
                            Layout.alignment: Qt.AlignHCenter

                            // Glow Ring
                            Rectangle {
                                id: glowRing
                                anchors.centerIn: parent
                                width: 32
                                height: 32
                                radius: 16
                                color: "transparent"
                                border.color: "#2ecc71"
                                border.width: 2.0

                                NumberAnimation on scale {
                                    from: 1.0
                                    to: 2.2
                                    duration: 1600
                                    loops: Animation.Infinite
                                    easing.type: Easing.OutQuad
                                }
                                OpacityAnimator on opacity {
                                    from: 0.8
                                    to: 0.0
                                    duration: 1600
                                    loops: Animation.Infinite
                                    easing.type: Easing.OutQuad
                                }
                            }

                            // Core
                            Rectangle {
                                id: pulsingDot
                                anchors.centerIn: parent
                                width: 32
                                height: 32
                                radius: 16
                                color: "#2ecc71" // Green

                                SequentialAnimation on opacity {
                                    loops: Animation.Infinite
                                    PropertyAnimation { to: 0.4; duration: 800; easing.type: Easing.InOutQuad }
                                    PropertyAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                                }
                            }
                        }

                        Text {
                            text: qsTr("LNG_00309").arg(rootSideBar.newVersionString)
                            color: updateArea.containsMouse ? "#55efc4" : "#2ecc71"
                            font.pixelSize: 11
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }
                    }
                }

                // Footer version link
                Text {
                    text: "<a href=\"https://github.com/optio50/KVision\" style=\"color: #8898a6; text-decoration: none;\">GitHub Project</a>"
                    font.pixelSize: 11
                    textFormat: Text.RichText
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    onLinkActivated: WebBrowser.open(link)
                }
            }
        }

        // Right Stack Panel showing selected page
        StackLayout {
            id: pagesStack
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: 3

            onCurrentIndexChanged: {
                rootSideBar.resetPathChangesCheckbox();
            }

            // PAGE 0: Viewport settings
            ScrollView {
                id: page0ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: page0Layout
                    x: 24
                    width: page0ScrollView.width - 48
                    spacing: 20

                    Text {
                        text: qsTr("LNG_00308")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    // Placeholder when no viewport is active
                    Text {
                        text: qsTr("LNG_00307")
                        color: "#8898a6"
                        font {
                            pixelSize: 13
                            italic: true
                        }
                        visible: rootSideBar.currentViewportIndex < 0
                        Layout.fillWidth: true
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 16
                        visible: rootSideBar.currentViewportIndex >= 0

                        Switch {
                            id: configUnlockSwitch
                            text: qsTr("LNG_00306")
                            checked: false
                            palette.highlight: "#4CAF50"
                            Layout.fillWidth: true
                        }

                        GroupBox {
                            title: qsTr("LNG_00305")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 12

                                TextField {
                                    text: (rootSideBar.currentViewportIndex >= 0 && Utils.currentModel()) ? Utils.currentModel().get(rootSideBar.currentViewportIndex).url : ""
                                    placeholderText: qsTr("LNG_00304")
                                    selectByMouse: true
                                    enabled: configUnlockSwitch.checked
                                    Layout.fillWidth: true
                                    onEditingFinished: {
                                        if (rootSideBar.currentViewportIndex >= 0) {
                                            Utils.currentModel().get(rootSideBar.currentViewportIndex).url = text;
                                            Utils.currentModel().get(rootSideBar.currentViewportIndex).streamMode = 0;
                                        }
                                    }
                                }

                                TextField {
                                    text: (rootSideBar.currentViewportIndex >= 0 && Utils.currentModel()) ? Utils.currentModel().get(rootSideBar.currentViewportIndex).secondaryUrl : ""
                                    placeholderText: qsTr("LNG_00303")
                                    selectByMouse: true
                                    enabled: configUnlockSwitch.checked
                                    Layout.fillWidth: true
                                    onEditingFinished: {
                                        if (rootSideBar.currentViewportIndex >= 0) {
                                            Utils.currentModel().get(rootSideBar.currentViewportIndex).secondaryUrl = text;
                                        }
                                    }
                                }
                            }
                        }

                        GroupBox {
                            title: qsTr("LNG_00302")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 12

                                Button {
                                    text: qsTr("LNG_00301")
                                    enabled: configUnlockSwitch.checked && (rootSideBar.currentViewportIndex >= 0 && Utils.currentLayout() ? Utils.currentLayout().get(rootSideBar.currentViewportIndex).hasAudio : false)
                                    highlighted: !(rootSideBar.currentViewportIndex >= 0 && Utils.currentModel() && Utils.currentModel().get(rootSideBar.currentViewportIndex).volume > 0 || !viewportSettings.noUnmuteWhenFullScreen && Utils.currentLayout() && Utils.currentLayout().fullScreenIndex >= 0)
                                    Layout.fillWidth: true
                                    onClicked: {
                                        var layout = Utils.currentLayout();
                                        if (rootSideBar.currentViewportIndex >= 0 && layout)
                                            layout.toggleTileMute(rootSideBar.currentViewportIndex);
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        text: qsTr("LNG_00300")
                                        color: "white"
                                        font.pixelSize: 11
                                    }

                                    TextField {
                                        text: (rootSideBar.currentViewportIndex >= 0 && Utils.currentModel()) ? getOptionsString(Utils.currentModel().get(rootSideBar.currentViewportIndex).avFormatOptions, Utils.currentModel().get(rootSideBar.currentViewportIndex).url) : ""
                                        selectByMouse: true
                                        enabled: configUnlockSwitch.checked
                                        Layout.fillWidth: true
                                        onEditingFinished: {
                                            if (rootSideBar.currentViewportIndex >= 0) {
                                                var options = Utils.parseOptions(text);
                                                var defaultAVFormatOptions = layoutsCollectionSettings.toJSValue("defaultAVFormatOptions");

                                                if (Object.keys(options).length == Object.keys(defaultAVFormatOptions).length) {
                                                    for (var key in options) {
                                                        if (defaultAVFormatOptions[key] === undefined || String(defaultAVFormatOptions[key]) !== String(options[key])) {
                                                            Utils.currentModel().get(rootSideBar.currentViewportIndex).avFormatOptions = options;
                                                            return;
                                                        }
                                                    }
                                                    Utils.currentModel().get(rootSideBar.currentViewportIndex).avFormatOptions = {};
                                                } else {
                                                    Utils.currentModel().get(rootSideBar.currentViewportIndex).avFormatOptions = options;
                                                }
                                            }
                                        }

                                        function getOptionsString(options, url) {
                                            Object.assignDefault(options, layoutsCollectionSettings.toJSValue("defaultAVFormatOptions"));
                                            var uriStr = String(url || "");
                                            var idx = uriStr.indexOf("hikvision://");
                                            if (idx !== -1) {
                                                var ipPort = uriStr.substring(idx + 12).split("/")[0].split("@").pop().split(":");
                                                var vpIp = ipPort[0] || "";
                                                var jsonStr = rootWindow.hikvisionRecordersJson;
                                                if (jsonStr) {
                                                    var recordersList = JSON.parse(jsonStr);
                                                    for (var i = 0; i < recordersList.length; ++i) {
                                                        var recIp = (recordersList[i].ip || "").trim();
                                                        var cleanRecIp = recIp.split(":")[0];
                                                        if (recIp === vpIp.trim() || cleanRecIp === vpIp.trim()) {
                                                            var transport = recordersList[i].rtspTransport || "";
                                                            if (transport === "tcp" || transport === "udp") {
                                                                options["rtsp_transport"] = transport;
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            return Utils.stringifyOptions(options);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // PAGE 1: Tools & Layout Options
            ScrollView {
                id: page1ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: page1Layout
                    x: 24
                    width: page1ScrollView.width - 48
                    spacing: 20

                    Text {
                        text: qsTr("LNG_00299")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    Switch {
                        id: toolsUnlockSwitch
                        text: qsTr("LNG_00298")
                        checked: false
                        palette.highlight: "#4CAF50"
                        Layout.fillWidth: true
                    }

                    GroupBox {
                        title: qsTr("LNG_00297")
                        enabled: toolsUnlockSwitch.checked && !(Utils.currentLayout() && Utils.currentLayout().fullScreenIndex >= 0)
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                                radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        GridLayout {
                            columns: 3
                            anchors.fill: parent
                            rowSpacing: 8
                            columnSpacing: 8

                            ListModel {
                                id: divisionModel

                                ListElement { size: "1x1" }
                                ListElement { size: "2x2" }
                                ListElement { size: "3x3" }
                                ListElement { size: "4x4" }
                                ListElement { size: "5x5" }
                                ListElement { size: "6x6" }
                                ListElement { size: "7x7" }
                                ListElement { size: "8x8" }
                                ListElement { size: "9x9" }

                                Component.onCompleted: {
                                    fromJSValue(sideBarSettings.windowDivision);
                                    divisionModel.dataChanged.connect(() => {
                                        sideBarSettings.windowDivision = JSON.stringify(toJSValue());
                                    });
                                }

                                function fromJSValue(model) {
                                    var arr;
                                    try {
                                        if (!model.isEmpty()) {
                                            arr = JSON.parse(model);
                                        }
                                    } catch(err) {
                                        Utils.log_error(qsTr("LNG_00219"));
                                    }

                                    if (arr instanceof Array) {
                                        for (var i = 0; i < arr.length; ++i) {
                                            divisionModel.set(i, arr[i]);
                                        }
                                    }
                                }

                                function toJSValue() {
                                    var arr = [];
                                    for (var i = 0; i < divisionModel.count; ++i) {
                                        arr[i] = divisionModel.get(i);
                                    }
                                    return arr;
                                }
                            }

                            Repeater {
                                model: divisionModel
                                delegate: Item {
                                    id: divisionItem
                                    implicitWidth: 100
                                    implicitHeight: 36
                                    Layout.fillWidth: true

                                    Keys.onEscapePressed: {
                                        event.accepted = divisionTextField.visible;
                                        divisionTextField.cancel();
                                    }
                                    Keys.onPressed: {
                                        if (event.key === Qt.Key_F2) {
                                            divisionTextField.edit();
                                        }
                                    }

                                    Button {
                                        text: size
                                        highlighted: Utils.currentModel() && Utils.currentModel().size === str2size(size)
                                        enabled: !generalSettings.lockGridSize
                                        anchors.fill: parent
                                        onClicked: {
                                            if (Utils.currentModel()) {
                                                Utils.currentModel().size = str2size(size);
                                            }
                                        }
                                        onPressAndHold: divisionTextField.edit()

                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("LNG_00296")
                                    }

                                    TextField {
                                        id: divisionTextField
                                        visible: false
                                        anchors.fill: parent
                                        horizontalAlignment: TextInput.AlignHCenter
                                        selectByMouse: true
                                        onEditingFinished: {
                                            visible = false;
                                            if(str2size(text)) {
                                                size = text;
                                            }
                                        }

                                        function edit() {
                                            text = size;
                                            visible = true;
                                            forceActiveFocus();
                                        }
                                        function cancel() {
                                            text = size;
                                            visible = false;
                                        }
                                    }

                                    function str2size(str) {
                                        var separatorTr = qsTr("LNG_00295");
                                        var regexp = new RegExp("^[1-9][x%1][1-9]$".arg(separatorTr));
                                        if (regexp.test(str)) {
                                            var size = str.split(new RegExp("[x%1]".arg(separatorTr)));
                                            return Qt.size(size[0], size[1]);
                                        }
                                        return null;
                                    }
                                }
                            }
                        }
                    }

                    GroupBox {
                        title: qsTr("LNG_00294")
                        enabled: toolsUnlockSwitch.checked
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 10

                            RowLayout {
                                spacing: 12
                                Layout.fillWidth: true

                                Button {
                                    text: "16:9 Aspect Ratio"
                                    highlighted: Utils.currentModel() && Utils.currentModel().aspectRatio === Qt.size(16, 9)
                                    Layout.fillWidth: true
                                    onClicked: {
                                        if (Utils.currentModel()) {
                                            Utils.currentModel().aspectRatio = Qt.size(16, 9);
                                            setRootWindowRatio(Utils.currentModel().aspectRatio);
                                        }
                                    }
                                }
                                Button {
                                    text: "4:3 Aspect Ratio"
                                    highlighted: Utils.currentModel() && Utils.currentModel().aspectRatio === Qt.size(4, 3)
                                    Layout.fillWidth: true
                                    onClicked: {
                                        if (Utils.currentModel()) {
                                            Utils.currentModel().aspectRatio = Qt.size(4, 3);
                                            setRootWindowRatio(Utils.currentModel().aspectRatio);
                                        }
                                    }
                                }
                            }

                            Button {
                                text: qsTr("LNG_00011")
                                highlighted: Context.config.fullScreen
                                Layout.fillWidth: true
                                onClicked: Context.config.fullScreen = !Context.config.fullScreen
                            }
                        }
                    }

                    GroupBox {
                        title: qsTr("LNG_00293")
                        enabled: toolsUnlockSwitch.checked
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        RowLayout {
                            anchors.fill: parent
                            spacing: 10

                            Button {
                                text: qsTr("LNG_00292")
                                enabled: Utils.currentLayout() ? Utils.currentLayout().mergeCells(true) : false
                                Layout.fillWidth: true
                                onClicked: if (Utils.currentLayout()) Utils.currentLayout().mergeCells()
                            }
                        }
                    }
                }
            }

            // PAGE 2: NVR Connection Recorders List
            ScrollView {
                id: page2ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: recordersLayout
                    x: 24
                    width: page2ScrollView.width - 48
                    spacing: 20

                    Text {
                        text: qsTr("LNG_00291")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    NvrSettingsPanel {
                        Layout.fillWidth: true
                    }
                }
            }

            // PAGE 3: Presets & Views list
            ScrollView {
                id: page3ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: presetsLayout
                    x: 24
                    width: page3ScrollView.width - 48
                    spacing: 20

                    Text {
                        text: qsTr("LNG_00290")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    GroupBox {
                        title: qsTr("Layouts")
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                Column {
                                    spacing: 8
                                    Layout.alignment: Qt.AlignVCenter

                                    Button {
                                        id: moveUpBtn
                                        implicitWidth: 36
                                        implicitHeight: 36
                                        enabled: rootSideBar.canMoveSavedLayout(rootSideBar.selectedLayoutIndex, -1)
                                        onClicked: rootSideBar.moveSavedLayout(rootSideBar.selectedLayoutIndex, -1)
                                        contentItem: Image {
                                            anchors.centerIn: parent
                                            width: 16
                                            height: 16
                                            source: {
                                                var colorStr = !moveUpBtn.enabled ? "%233a4550" : (moveUpBtn.hovered ? "%23ffffff" : "%238898a6");
                                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='6 14 12 8 18 14'></polyline></svg>";
                                            }
                                        }
                                        background: Rectangle {
                                            color: moveUpBtn.pressed ? "#cc121214" : (moveUpBtn.hovered && moveUpBtn.enabled ? "#3a4550" : "#1c242c")
                                            radius: 18
                                            border.color: moveUpBtn.enabled ? (moveUpBtn.hovered ? "#8898a6" : "#2a3540") : "#1c242c"
                                            border.width: 1
                                        }
                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.visible: moveUpBtn.hovered && moveUpBtn.enabled
                                        ToolTip.text: qsTr("Move the selected layout up")
                                    }

                                    Button {
                                        id: moveDownBtn
                                        implicitWidth: 36
                                        implicitHeight: 36
                                        enabled: rootSideBar.canMoveSavedLayout(rootSideBar.selectedLayoutIndex, 1)
                                        onClicked: rootSideBar.moveSavedLayout(rootSideBar.selectedLayoutIndex, 1)
                                        contentItem: Image {
                                            anchors.centerIn: parent
                                            width: 16
                                            height: 16
                                            source: {
                                                var colorStr = !moveDownBtn.enabled ? "%233a4550" : (moveDownBtn.hovered ? "%23ffffff" : "%238898a6");
                                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='6 10 12 16 18 10'></polyline></svg>";
                                            }
                                        }
                                        background: Rectangle {
                                            color: moveDownBtn.pressed ? "#cc121214" : (moveDownBtn.hovered && moveDownBtn.enabled ? "#3a4550" : "#1c242c")
                                            radius: 18
                                            border.color: moveDownBtn.enabled ? (moveDownBtn.hovered ? "#8898a6" : "#2a3540") : "#1c242c"
                                            border.width: 1
                                        }
                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.visible: moveDownBtn.hovered && moveDownBtn.enabled
                                        ToolTip.text: qsTr("Move the selected layout down")
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                            Repeater {
                                model: rootSideBar.savedLayoutIndices
                                delegate: RowLayout {
                                    id: presetRow
                                    spacing: 12
                                    Layout.fillWidth: true

                                    property var layout: {
                                        var order = rootWindow.layoutOrderRevision;
                                        if (order < 0)
                                            return null;
                                        return layoutsCollectionModel.get(modelData);
                                    }

                                    // Active preset indicator
                                    Rectangle {
                                        width: 4
                                        height: 24
                                        radius: 2
                                        color: stackLayout.currentIndex === modelData ? "#00f5d4" : "transparent"
                                    }

                                    // Editable preset name field
                                    TextField {
                                        id: nameField
                                        text: (presetRow.layout && presetRow.layout.name) ? presetRow.layout.name : ""
                                        placeholderText: qsTr("LNG_00288").arg(index + 1)
                                        selectByMouse: true
                                        Layout.fillWidth: true
                                        color: "white"
                                        background: Rectangle {
                                            color: "#0f151b"
                                            radius: 4
                                            border.color: rootSideBar.selectedLayoutIndex === modelData ? "#00f5d4" : (nameField.activeFocus ? "#ff7a00" : "#2a3540")
                                        }
                                        onPressed: rootSideBar.selectedLayoutIndex = modelData
                                        onEditingFinished: {
                                            if (presetRow.layout) {
                                                presetRow.layout.name = text;
                                            }
                                        }
                                    }

                                    // Toolbar checkbox
                                    CheckBox {
                                        text: qsTr("Toolbar")
                                        ToolTip.visible: hovered
                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.text: qsTr("Show this layout on the top toolbar")
                                        checked: presetRow.layout ? presetRow.layout.visible : true
                                        onCheckedChanged: {
                                            if (presetRow.layout) {
                                                presetRow.layout.visible = checked;
                                            }
                                        }
                                        palette.highlight: "#00f5d4"
                                    }

                                    // Activate button
                                    Button {
                                        id: activateBtn
                                        implicitWidth: 28
                                        implicitHeight: 28
                                        highlighted: stackLayout.currentIndex === modelData
                                        onClicked: {
                                            stackLayout.currentIndex = modelData;
                                        }
                                        contentItem: Image {
                                            anchors.centerIn: parent
                                            width: 14
                                            height: 14
                                            source: {
                                                var colorStr = activateBtn.pressed ? "%23ffffff" : (activateBtn.highlighted ? "%23ffffff" : (activateBtn.hovered ? "%23ffffff" : "%238898a6"));
                                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polygon points='6 3 20 12 6 21 6 3'></polygon></svg>";
                                            }
                                        }
                                        background: Rectangle {
                                            color: activateBtn.pressed ? "#cc121214" : (activateBtn.highlighted ? "#ff7a00" : (activateBtn.hovered ? "#3a4550" : "#1c242c"))
                                            radius: 14
                                            border.color: activateBtn.highlighted ? "#ff9e00" : (activateBtn.hovered ? "#8898a6" : "#2a3540")
                                            border.width: 1
                                        }
                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.visible: activateBtn.hovered
                                        ToolTip.text: qsTr("LNG_00287")
                                    }

                                    LayoutBackupButton {
                                        layoutUid: (presetRow.layout && presetRow.layout.uid) ? presetRow.layout.uid : ""
                                        onActivated: layoutBackupDialog.openFor(modelData)
                                    }

                                    // Delete icon button
                                    Button {
                                        id: delPresetBtn
                                        implicitWidth: 28
                                        implicitHeight: 28
                                        visible: rootSideBar.savedLayoutIndices.length > 1
                                        contentItem: Image {
                                            anchors.centerIn: parent
                                            width: 14
                                            height: 14
                                            source: {
                                                var colorStr = delPresetBtn.hovered ? "%23ff4d4d" : "%238898a6";
                                                return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='" + colorStr + "' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='3 6 5 6 21 6'></polyline><path d='M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2'></path><line x1='10' y1='11' x2='10' y2='17'></line><line x1='14' y1='11' x2='14' y2='17'></line></svg>";
                                            }
                                        }
                                        background: Rectangle {
                                            color: delPresetBtn.pressed ? "#40ff0000" : (delPresetBtn.hovered ? "#20ff0000" : "transparent")
                                            radius: 14
                                            border.color: delPresetBtn.hovered ? "#ff4d4d" : "#2a3540"
                                            border.width: 1
                                        }

                                        onClicked: {
                                            presetDeleteDialog.index = modelData;
                                            presetDeleteDialog.open();
                                        }
                                        ToolTip.delay: Compact.toolTipDelay
                                        ToolTip.timeout: Compact.toolTipTimeout
                                        ToolTip.visible: delPresetBtn.hovered
                                        ToolTip.text: qsTr("LNG_00286")
                                    }
                                }
                            }
                                }
                            }

                            Button {
                                id: addPresetBtn
                                text: qsTr("LNG_00285")
                                Layout.fillWidth: true
                                implicitHeight: 32
                                onClicked: {
                                    var l = layoutsCollectionModel.append();
                                    l.visible = true;
                                    l.size = Qt.size(3, 3);
                                }
                                background: Rectangle {
                                    color: addPresetBtn.pressed ? "#cc121214" : (addPresetBtn.hovered ? "#059669" : "#10b981")
                                    radius: 6
                                    border.color: addPresetBtn.hovered ? "#34d399" : "#059669"
                                    border.width: 1
                                }
                                contentItem: Text {
                                    text: addPresetBtn.text
                                    color: "#ffffff"
                                    font.bold: true
                                    font.pixelSize: 11
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }

                    // Layouts that were deleted but still have backups
                    Button {
                        id: recoverLayoutBtn
                        Layout.fillWidth: true
                        implicitHeight: 30
                        visible: rootSideBar.deletedBackupCount > 0
                        text: qsTr("Recover a deleted layout (%1)").arg(rootSideBar.deletedBackupCount)
                        onClicked: layoutBackupDialog.openRecover()
                        contentItem: Text {
                            text: recoverLayoutBtn.text
                            color: recoverLayoutBtn.hovered ? "#00f5d4" : "#c8d2da"
                            font.pixelSize: 11
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: recoverLayoutBtn.hovered ? "#1f2a34" : "transparent"
                            radius: 6
                            border.color: recoverLayoutBtn.hovered ? "#00f5d4" : "#2a3540"
                        }
                        ToolTip.visible: hovered
                        ToolTip.delay: Compact.toolTipDelay
                        ToolTip.timeout: Compact.toolTipTimeout
                        ToolTip.text: qsTr("Layouts that were deleted but still have backups. Pick one to put it back.")
                    }

                }
            }

            // PAGE 4: General application settings
            ScrollView {
                id: page4ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: page4Layout
                    x: 24
                    width: page4ScrollView.width - 48
                    spacing: 20
                    property int section: 0 // the shown settings section: Detection, NVR, Cameras and display, Audio, General, Camera Tools

                    Text {
                        text: qsTr("LNG_00274")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    Row {
                        spacing: 6
                        Repeater {
                            model: [qsTr("Detection"), qsTr("NVR"), qsTr("Cameras and display"), qsTr("Audio"), qsTr("General"), qsTr("Camera Tools")]
                            delegate: Rectangle {
                                readonly property bool selected: page4Layout.section === index
                                width: tabLabel.implicitWidth + 32
                                height: 34
                                radius: 6
                                color: selected ? "#1c242c" : (tabArea.containsMouse ? "#141a21" : "transparent")
                                border.width: 1
                                border.color: selected ? "#00f5d4" : "#2a3540"
                                Text {
                                    id: tabLabel
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: parent.selected ? "#00f5d4" : "#cccccc"
                                    font.pixelSize: 13
                                    font.bold: parent.selected
                                }
                                MouseArea {
                                    id: tabArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: page4Layout.section = index
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section0
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 0

                        GroupBox {
                            title: qsTr("Detection frame")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("Show a frame and label on a camera when it detects a human, vehicle or animal (detection must be set up correctly on the camera or the NVR)")
                                    checked: generalSettings.showTargetIndicator
                                    onCheckedChanged: generalSettings.showTargetIndicator = checked
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                    text: qsTr("Keep the frame visible for %1 s after the last report").arg(targetHoldSlider.value.toFixed(0))
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                Slider {
                                    id: targetHoldSlider
                                    Layout.fillWidth: true
                                    from: 3
                                    to: 30
                                    stepSize: 1
                                    enabled: generalSettings.showTargetIndicator
                                    value: generalSettings.targetHoldSeconds
                                    onMoved: generalSettings.targetHoldSeconds = value
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    SelectableLabel {
                                        text: qsTr("Show a tile frame highlight and label for these kinds of report")
                                        textColor: "#8898a6"
                                        font.pixelSize: 11
                                        wrapMode: TextEdit.Wrap
                                        Layout.fillWidth: true
                                    }

                                    HelpMark {
                                        Layout.alignment: Qt.AlignTop
                                        tip: qsTr("These tick boxes only change what is drawn on a tile: the colored border and the label. They do not change what the camera detects, what is written to the detection log, or which event pictures are saved. (Plain motion that names no target is logged only if \"Write plain motion to the detection log\" is on, and Frames.log, which lists what the tiles showed, does follow these tick boxes.)")
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    enabled: generalSettings.showTargetIndicator

                                    Repeater {
                                        model: [
                                            { key: "motion", label: qsTr("Motion") },
                                            { key: "line", label: qsTr("Line crossing") },
                                            { key: "intrusion", label: qsTr("Intrusion") },
                                            { key: "enter", label: qsTr("Region entrance") },
                                            { key: "exit", label: qsTr("Region exit") },
                                            { key: "face", label: qsTr("Face detection") },
                                            { key: "other", label: qsTr("Other smart events") }
                                        ]
                                        delegate: CheckBox {
                                            text: modelData.label
                                            checked: ("," + generalSettings.targetKinds + ",").indexOf("," + modelData.key + ",") >= 0
                                            onToggled: generalSettings.targetKinds = rootSideBar.toggledList(generalSettings.targetKinds, modelData.key, checked)
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    SelectableLabel {
                                        text: qsTr("Show a tile frame highlight and label for these targets")
                                        textColor: "#8898a6"
                                        font.pixelSize: 11
                                        wrapMode: TextEdit.Wrap
                                        Layout.fillWidth: true
                                    }

                                    HelpMark {
                                        Layout.alignment: Qt.AlignTop
                                        tip: qsTr("These tick boxes only change what is drawn on a tile: the colored border and the label. They do not change what the camera detects, what is written to the detection log, or which event pictures are saved. (Plain motion that names no target is logged only if \"Write plain motion to the detection log\" is on, and Frames.log, which lists what the tiles showed, does follow these tick boxes.)")
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    enabled: generalSettings.showTargetIndicator

                                    Repeater {
                                        model: [
                                            { key: "human", label: qsTr("Human") },
                                            { key: "vehicle", label: qsTr("Vehicle") },
                                            { key: "animal", label: qsTr("Animal") },
                                            { key: "other", label: qsTr("Other") }
                                        ]
                                        delegate: CheckBox {
                                            text: modelData.label
                                            checked: ("," + generalSettings.targetTargets + ",").indexOf("," + modelData.key + ",") >= 0
                                            onToggled: generalSettings.targetTargets = rootSideBar.toggledList(generalSettings.targetTargets, modelData.key, checked)
                                        }
                                    }
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("Where detection events come from")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                SelectableLabel {
                                    text: qsTr("Where cameras behind a recorder get their detection reports")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                ComboBox {
                                    id: targetSourceBox
                                    Layout.fillWidth: true
                                    enabled: generalSettings.showTargetIndicator
                                    model: [qsTr("Each camera directly (one connection per camera)"),
                                            qsTr("Through the recorder (one connection, no pause between reports)")]
                                    currentIndex: generalSettings.targetSource === "recorder" ? 1 : 0
                                    onActivated: generalSettings.targetSource = (index === 1 ? "recorder" : "camera")
                                }

                                SelectableLabel {
                                    text: qsTr("A standalone camera, a dual-lens camera, and a recorder with one or two cameras always use their own connection. Through the recorder needs the camera's smart event metadata and Notify Surveillance Center switched on.")
                                    textColor: "#6f7f8c"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                text: qsTr("To choose differently for one camera behind a recorder, open the list below. It also sets where each camera shows a detection frame. A camera is read from one place only, so nothing is logged twice.")
                                textColor: "#6f7f8c"
                                font.pixelSize: 10
                                wrapMode: TextEdit.Wrap
                                Layout.fillWidth: true
                                }

                                Button {
                                    text: qsTr("Choose cameras and event source...")
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: qsTr("For each camera: whether it shows a detection frame, and where its detection events come from (the camera or the NVR)")
                                    onClicked: {
                                        var w = detectionFramesComponent.createObject(rootWindow);
                                        if (w)
                                            w.show();
                                    }
                                }

                                Component {
                                    id: detectionFramesComponent
                                    DetectionFramesWindow {}
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("Plain motion (no person, vehicle or animal named)")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                SelectableLabel {
                                    text: qsTr("What to do with plain motion reports")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                    text: qsTr("Some cameras (a panoramic camera, for example) can only say that something moved, not what it was. They cannot tell a person from a car, so there is no person, vehicle or animal in the report. KVision ignores these reports unless you tick one of the boxes below.")
                                    textColor: "#6f7f8c"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("Write plain motion to the detection log (no picture)")
                                    checked: generalSettings.logUnlabelledMotion
                                    onToggled: generalSettings.logUnlabelledMotion = checked
                                }

                                CheckBox {
                                    text: qsTr("Show a MOTION frame on the camera when plain motion is reported")
                                    enabled: generalSettings.showTargetIndicator
                                    checked: generalSettings.frameUnlabelledMotion
                                    onToggled: generalSettings.frameUnlabelledMotion = checked
                                }

                                SelectableLabel {
                                    text: qsTr("A camera repeats a plain motion report about once a second while something moves, so the log gets one line when the movement starts and the next only after 10 seconds without motion. Reports that name a person, vehicle or animal are always logged, whatever is ticked here. The MOTION frame also needs the frame option at the top of this page.")
                                    textColor: "#6f7f8c"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("Face detection pictures")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                SelectableLabel {
                                    text: qsTr("A face report brings no photo of its own. With this on, KVision takes a still as soon as a face is reported, then another 1 second later and another 3 seconds later, only while the camera is still reporting that face. After 10 seconds with no face, the next report starts a new set. The detection log still has one line for the visit, and the log viewer shows the stills with that line.")
                                    textColor: "#6f7f8c"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("Save stills when a face is reported")
                                    checked: generalSettings.pictureFaceDetection
                                    onToggled: generalSettings.pictureFaceDetection = checked
                                }

                                SelectableLabel {
                                    text: qsTr("These stills are kept to a smaller number than line and intrusion pictures, so a busy face camera cannot push those out. The Face detection tick above only changes the tile label. It does not save a picture. Use the camera as the detection source so the still comes from that camera.")
                                    textColor: "#6f7f8c"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("Detection log and pictures")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    id: logDetectionsBox
                                    text: qsTr("Keep logging detection events after KVision is closed")
                                    checked: generalSettings.logDetectionEvents
                                    onToggled: {
                                        generalSettings.logDetectionEvents = checked;
                                        var err = HikvisionEventLogger.setBackgroundService(checked, Context.config.fileName);
                                        logDetectionsNote.text = err !== "" ? qsTr("Could not change the background service: %1").arg(err) : "";
                                        bgStatusTimer.restart();
                                        logDetectionsStatus.text = HikvisionEventLogger.backgroundStatus(Context.configDirPath());
                                    }
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                    text: qsTr("While KVision is open it always logs every configured camera, whether or not it is on screen. With this on, a small background service takes over when KVision closes and steps aside when it opens again. With this off, nothing is logged while KVision is closed. The frame and label in User Interface Settings only control what is drawn on screen; they do not affect the log.")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                Text {
                                    id: logDetectionsStatus
                                    visible: generalSettings.logDetectionEvents
                                    color: text.indexOf("OK") >= 0 || text.indexOf("standing by") >= 0 ? "#00f5d4" : "#ff9f43"
                                    font.pixelSize: 11
                                    font.bold: true
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }

                                Text {
                                    id: logDetectionsNote
                                    visible: text !== ""
                                    color: "#ff4d4d"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }

                                Timer {
                                    id: bgStatusTimer
                                    interval: 5000
                                    repeat: true
                                    running: generalSettings.logDetectionEvents && logDetectionsBox.visible
                                    triggeredOnStart: true
                                    onTriggered: logDetectionsStatus.text = HikvisionEventLogger.backgroundStatus(Context.configDirPath())
                                }

                                Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#2a3540"
                                }

                                SelectableLabel {
                                    text: qsTr("Event pictures kept for each camera (the newest ones; older ones are deleted)")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                ComboBox {
                                    Layout.fillWidth: true
                                    model: [100, 500, 1000]
                                    currentIndex: Math.max(0, model.indexOf(generalSettings.picturesPerCamera))
                                    onActivated: generalSettings.picturesPerCamera = model[index]
                                }

                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section1
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 1

                        GroupBox {
                            title: qsTr("NVR Status Monitoring")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("LNG_00270")
                                    checked: NvrStatusManager.monitoringEnabled
                                    onCheckedChanged: NvrStatusManager.monitoringEnabled = checked
                                    Layout.fillWidth: true
                                }

                                Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#2a3540"
                                }

                                CheckBox {
                                    text: qsTr("LNG_00248")
                                    checked: NvrStatusManager.checkOffline
                                    onCheckedChanged: NvrStatusManager.checkOffline = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00247")
                                    checked: NvrStatusManager.checkCpu
                                    onCheckedChanged: NvrStatusManager.checkCpu = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00246")
                                    checked: NvrStatusManager.checkHw
                                    onCheckedChanged: NvrStatusManager.checkHw = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00245")
                                    checked: NvrStatusManager.checkHdd
                                    onCheckedChanged: NvrStatusManager.checkHdd = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00244")
                                    checked: NvrStatusManager.checkUnformatted
                                    onCheckedChanged: NvrStatusManager.checkUnformatted = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00243")
                                    checked: NvrStatusManager.checkFull
                                    onCheckedChanged: NvrStatusManager.checkFull = checked
                                    Layout.fillWidth: true
                                }

                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section2
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 2

                        GroupBox {
                            title: qsTr("LNG_00266")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("LNG_00265")
                                    checked: generalSettings.enableContextMenu
                                    onCheckedChanged: generalSettings.enableContextMenu = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00264")
                                    checked: generalSettings.allowSwappingViewports
                                    enabled: generalSettings.enableContextMenu
                                    onCheckedChanged: generalSettings.allowSwappingViewports = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00263")
                                    checked: generalSettings.enableRemoveCamera
                                    enabled: generalSettings.enableContextMenu
                                    onCheckedChanged: generalSettings.enableRemoveCamera = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00262")
                                    checked: generalSettings.enableChangeViewportSettings
                                    enabled: generalSettings.enableContextMenu
                                    onCheckedChanged: generalSettings.enableChangeViewportSettings = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00261")
                                    checked: generalSettings.enableStreamSelection
                                    enabled: generalSettings.enableContextMenu
                                    onCheckedChanged: generalSettings.enableStreamSelection = checked
                                    Layout.fillWidth: true
                                }
                            }
                        }

                        GroupBox {
                            title: qsTr("User Interface Settings")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("LNG_00259")
                                    checked: viewSettings.showChannelStatus
                                    onCheckedChanged: viewSettings.showChannelStatus = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00578")
                                    checked: viewSettings.showChannelResolution
                                    onCheckedChanged: viewSettings.showChannelResolution = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00579")
                                    checked: viewSettings.hideInfoBadgesWhenIdle
                                    onCheckedChanged: viewSettings.hideInfoBadgesWhenIdle = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00258")
                                    checked: viewSettings.showCameraInfo
                                    onCheckedChanged: viewSettings.showCameraInfo = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00257")
                                    checked: viewSettings.hoverControlIcons
                                    onCheckedChanged: viewSettings.hoverControlIcons = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00256")
                                    checked: viewSettings.showInfoOnHoverOnly
                                    onCheckedChanged: viewSettings.showInfoOnHoverOnly = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00255")
                                    checked: viewSettings.showTopBarByDefault
                                    onCheckedChanged: viewSettings.showTopBarByDefault = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00254")
                                    checked: viewSettings.hideCursorWhenFullScreen
                                    onCheckedChanged: viewSettings.hideCursorWhenFullScreen = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("Hide cursor and viewport buttons when idle (windowed mode)")
                                    checked: viewSettings.hideCursorWhenWindowed
                                    onCheckedChanged: viewSettings.hideCursorWhenWindowed = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00253")
                                    checked: viewSettings.disableViewportZoomAnimation
                                    onCheckedChanged: viewSettings.disableViewportZoomAnimation = checked
                                    Layout.fillWidth: true
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text: qsTr("LNG_00250")
                                        color: "white"
                                        font.pixelSize: 13
                                    }

                                    TextField {
                                        id: auxiliaryLimitField
                                        Layout.preferredWidth: 40
                                        Layout.preferredHeight: 30
                                        horizontalAlignment: TextInput.AlignHCenter
                                        selectByMouse: true
                                        text: generalSettings.auxiliaryLimit.toString()
                                        color: "white"
                                        font.pixelSize: 12
                                        maximumLength: 1
                                        validator: IntValidator { bottom: 0; top: 3 }
                                        background: Rectangle {
                                            color: "#0f151b"
                                            radius: 4
                                            border.color: auxiliaryLimitField.activeFocus ? "#ff7a00" : "#2a3540"
                                        }
                                        onTextChanged: {
                                            var val = parseInt(text);
                                            if (!isNaN(val) && val > 3) {
                                                text = "3";
                                            }
                                        }
                                        onEditingFinished: {
                                            var val = parseInt(text);
                                            if (!isNaN(val) && val >= 0 && val <= 3) {
                                                generalSettings.auxiliaryLimit = val;
                                            } else {
                                                text = generalSettings.auxiliaryLimit.toString();
                                            }
                                        }
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text: qsTr("Auxiliary window size")
                                        color: "white"
                                        font.pixelSize: 13
                                    }

                                    ComboBox {
                                        id: auxiliaryScaleBox
                                        Layout.preferredWidth: 220
                                        Layout.preferredHeight: 30
                                        model: [qsTr("Same as the main window"), qsTr("Normal (1)"), qsTr("Medium (1.5)"), qsTr("Large (2)")]
                                        onActivated: generalSettings.auxiliaryScale = ["same", "1", "1.5", "2"][index]
                                        Component.onCompleted: currentIndex = rootSideBar.auxiliaryScaleIndex()
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: qsTr("Applies the next time an auxiliary window opens. Normal fits a 1080p or 720p screen. Medium is for 1440p. Large is for a 4K screen.")
                                    color: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text: qsTr("System Stats temperature")
                                        color: "white"
                                        font.pixelSize: 13
                                    }

                                    ComboBox {
                                        id: statsTempUnitBox
                                        Layout.preferredWidth: 150
                                        Layout.preferredHeight: 30
                                        model: [qsTr("Celsius (C)"), qsTr("Fahrenheit (F)")]
                                        onActivated: generalSettings.statsTemperatureUnit = index === 1 ? "F" : "C"
                                        Component.onCompleted: currentIndex = generalSettings.statsTemperatureUnit === "F" ? 1 : 0
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: qsTr("The temperature graph on the System Stats panel. Celsius is the default.")
                                    color: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                }

                                Button {
                                    text: qsTr("Overlay text from MQTT...")
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: qsTr("Show a value from an MQTT broker (such as the outside temperature) in a camera's on-screen text, refreshed every few minutes")
                                    onClicked: {
                                        var w = overlayTextComponent.createObject(rootWindow);
                                        if (w)
                                            w.show();
                                    }
                                }

                                Component {
                                    id: overlayTextComponent
                                    OverlayTextWindow {}
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("LNG_00242")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        text: qsTr("LNG_00241")
                                        color: "white"
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        TextField {
                                            id: playbackOffsetSecondsField
                                            Layout.preferredWidth: 100
                                            Layout.preferredHeight: 30
                                            selectByMouse: true
                                            text: generalSettings.playbackOffsetSeconds.toString()
                                            color: "white"
                                            font.pixelSize: 12
                                            maximumLength: 7
                                            validator: IntValidator { bottom: 0; top: 9999999 }
                                            background: Rectangle {
                                                color: "#0f151b"
                                                radius: 4
                                                border.color: playbackOffsetSecondsField.activeFocus ? "#ff7a00" : "#2a3540"
                                            }
                                            onEditingFinished: {
                                                var val = parseInt(text)
                                                if (!isNaN(val) && val >= 0) {
                                                    generalSettings.playbackOffsetSeconds = val
                                                } else {
                                                    text = generalSettings.playbackOffsetSeconds.toString()
                                                }
                                            }
                                        }

                                        Item {
                                            Layout.fillWidth: true
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        text: qsTr("LNG_00240")
                                        color: "white"
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        TextField {
                                            id: playbackTimelineHoursField
                                            Layout.preferredWidth: 60
                                            Layout.preferredHeight: 30
                                            selectByMouse: true
                                            text: generalSettings.playbackTimelineHours.toString()
                                            color: "white"
                                            font.pixelSize: 12
                                            maximumLength: 2
                                            validator: IntValidator { bottom: 1; top: 24 }
                                            background: Rectangle {
                                                color: "#0f151b"
                                                radius: 4
                                                border.color: playbackTimelineHoursField.activeFocus ? "#ff7a00" : "#2a3540"
                                            }
                                            onEditingFinished: {
                                                var val = parseInt(text)
                                                if (!isNaN(val) && val >= 1 && val <= 24) {
                                                    generalSettings.playbackTimelineHours = val
                                                } else {
                                                    text = generalSettings.playbackTimelineHours.toString()
                                                }
                                            }
                                        }

                                        Item {
                                            Layout.fillWidth: true
                                        }
                                    }
                                }

                                CheckBox {
                                    text: qsTr("Pause live view while archive playback is open")
                                    checked: generalSettings.pauseLiveDuringPlayback
                                    onCheckedChanged: generalSettings.pauseLiveDuringPlayback = checked
                                    Layout.fillWidth: true
                                    hoverEnabled: true
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: qsTr("Drops the live pictures on this window while the archive is open, and connects them again when it closes. Playback stays smooth when many cameras are on screen.")
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section3
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 3

                        GroupBox {
                            title: qsTr("LNG_00269")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("LNG_00268")
                                    checked: generalSettings.disableAudio
                                    onCheckedChanged: generalSettings.disableAudio = checked
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: qsTr("Repair Hikvision live audio")
                                    color: "#c5d0d8"
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                }

                                Button {
                                    text: qsTr("Choose cameras...")
                                    Layout.fillWidth: true
                                    hoverEnabled: true
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: qsTr("Tick a camera whose live sound was dropped. Only ticked cameras are repaired on this computer. Every other camera stays as it is.")
                                    onClicked: rootWindow.openAacRepairWindow()
                                }

                                CheckBox {
                                    text: qsTr("LNG_00267")
                                    checked: viewportSettings.noUnmuteWhenFullScreen
                                    onCheckedChanged: viewportSettings.noUnmuteWhenFullScreen = checked
                                    Layout.fillWidth: true
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#2a3540"
                                }

                                CheckBox {
                                    text: qsTr("Turn off the Talk button (two-way audio)")
                                    checked: generalSettings.disableTalk
                                    onCheckedChanged: generalSettings.disableTalk = checked
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                    text: qsTr("Talk microphone")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                }

                                ComboBox {
                                    id: talkMicCombo
                                    Layout.fillWidth: true
                                    enabled: !generalSettings.disableTalk
                                    property var mics: []
                                    model: [qsTr("System default")].concat(mics)
                                    Component.onCompleted: {
                                        mics = HikvisionTalk.microphones();
                                        var i = mics.indexOf(generalSettings.talkMicrophone);
                                        currentIndex = i >= 0 ? i + 1 : 0;
                                    }
                                    onActivated: generalSettings.talkMicrophone = index === 0 ? "" : mics[index - 1]
                                }

                                SelectableLabel {
                                    text: qsTr("Talk microphone gain: %1x").arg(talkGainSlider.value.toFixed(1))
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                }

                                Slider {
                                    id: talkGainSlider
                                    Layout.fillWidth: true
                                    from: 0.5
                                    to: 4.0
                                    stepSize: 0.1
                                    enabled: !generalSettings.disableTalk
                                    value: generalSettings.talkGain
                                    onMoved: generalSettings.talkGain = value
                                }

                                SelectableLabel {
                                    text: qsTr("Talk output boost: %1 dB (louder at the camera speaker)").arg((talkBoostSlider.value >= 0 ? "+" : "") + talkBoostSlider.value.toFixed(0))
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                Slider {
                                    id: talkBoostSlider
                                    Layout.fillWidth: true
                                    from: -6
                                    to: 12
                                    stepSize: 1
                                    enabled: !generalSettings.disableTalk
                                    value: generalSettings.talkBoostDb
                                    onMoved: generalSettings.talkBoostDb = value
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section4
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 4

                        GroupBox {
                            title: qsTr("General Settings")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                CheckBox {
                                    text: qsTr("LNG_00272")
                                    checked: !generalSettings.singleApplication
                                    enabled: false
                                    onCheckedChanged: generalSettings.singleApplication = !checked
                                    Layout.fillWidth: true
                                }

                                SelectableLabel {
                                    text: qsTr("LNG_00271")
                                    textColor: "#8898a6"
                                    font.pixelSize: 10
                                    wrapMode: TextEdit.WordWrap
                                    Layout.fillWidth: true
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#2a3540"
                                }

                                CheckBox {
                                    text: qsTr("LNG_00549")
                                    checked: generalSettings.enableDiagnosticLogs
                                    onCheckedChanged: generalSettings.enableDiagnosticLogs = checked
                                    Layout.fillWidth: true
                                }

                                CheckBox {
                                    text: qsTr("LNG_00577")
                                    checked: generalSettings.confirmOnClose
                                    onCheckedChanged: generalSettings.confirmOnClose = checked
                                    Layout.fillWidth: true
                                }

                            }
                        }

                        GroupBox {
                            title: qsTr("Web browser")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 8

                                SelectableLabel {
                                    text: qsTr("The browser KVision opens web pages in: a camera's own page, the recorder's page, the project's links. It is started directly, so it is used even when another browser is already open.")
                                    textColor: "#8898a6"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.Wrap
                                    Layout.fillWidth: true
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    ComboBox {
                                        id: browserCombo
                                        Layout.fillWidth: true
                                        property var found: []
                                        // 0 = system default, then the browsers found, then "another command"
                                        model: [qsTr("System default")].concat(found.map(function(b) { return b.name; })).concat([qsTr("Another command...")])
                                        Component.onCompleted: {
                                            found = WebBrowser.browsers();
                                            browserCombo.syncFromSetting();
                                        }
                                        function syncFromSetting() {
                                            var c = generalSettings.webBrowserChoice;
                                            if (c.indexOf("cmd:") === 0) {
                                                currentIndex = found.length + 1;
                                                return;
                                            }
                                            for (var i = 0; i < found.length; ++i) {
                                                if (c === "id:" + found[i].id) {
                                                    currentIndex = i + 1;
                                                    return;
                                                }
                                            }
                                            currentIndex = 0;
                                        }
                                        onActivated: {
                                            if (index === 0)
                                                generalSettings.webBrowserChoice = "";
                                            else if (index <= found.length)
                                                generalSettings.webBrowserChoice = "id:" + found[index - 1].id;
                                            else
                                                generalSettings.webBrowserChoice = "cmd:" + customBrowserField.text;
                                        }
                                    }

                                    Button {
                                        id: browserTestBtn
                                        text: qsTr("Test")
                                        onClicked: {
                                            browserNote.text = WebBrowser.open("https://github.com/optio50/KVision")
                                                ? qsTr("Opened the KVision page in the chosen browser.")
                                                : qsTr("Could not open it. Check the choice.");
                                        }
                                    }
                                }

                                TextField {
                                    id: customBrowserField
                                    Layout.fillWidth: true
                                    visible: browserCombo.currentIndex === browserCombo.found.length + 1
                                    placeholderText: qsTr("Command, e.g. brave-browser --new-window %u   (%u is where the address goes)")
                                    selectByMouse: true
                                    color: "white"
                                    text: generalSettings.webBrowserChoice.indexOf("cmd:") === 0 ? generalSettings.webBrowserChoice.substring(4) : ""
                                    background: Rectangle { color: "#0f151b"; radius: 4; border.color: customBrowserField.activeFocus ? "#ff7a00" : "#2a3540" }
                                    onEditingFinished: generalSettings.webBrowserChoice = "cmd:" + text
                                }

                                SelectableLabel {
                                    id: browserNote
                                    Layout.fillWidth: true
                                    wrapMode: TextEdit.Wrap
                                    font.pixelSize: 11
                                    textColor: "#8898a6"
                                    text: WebBrowser.describe() !== "" ? qsTr("Runs: %1").arg(WebBrowser.describe()) : qsTr("Uses the system's default browser.")
                                }
                            }
                        }

                        GroupBox {
                            title: qsTr("LNG_00239")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 12

                                CheckBox {
                                    id: activatePathChangesCheckbox
                                    text: qsTr("LNG_00231")
                                    checked: false
                                    Layout.fillWidth: true
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 12
                                    enabled: activatePathChangesCheckbox.checked
                                    opacity: activatePathChangesCheckbox.checked ? 1.0 : 0.5

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Text {
                                            text: qsTr("LNG_00238")
                                            color: "white"
                                            font.pixelSize: 11
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8

                                            TextField {
                                                id: snapshotPathField
                                                Layout.fillWidth: true
                                                selectByMouse: true
                                                text: generalSettings.snapshotPath
                                                color: "white"
                                                font.pixelSize: 12
                                                background: Rectangle {
                                                    color: "#0f151b"
                                                    radius: 4
                                                    border.color: snapshotPathField.activeFocus ? "#ff7a00" : "#2a3540"
                                                }
                                                onEditingFinished: {
                                                    generalSettings.snapshotPath = text
                                                    Context.mkpath(text)
                                                }
                                            }

                                            Button {
                                                id: btnBrowseSnapshot
                                                text: "..."
                                                Layout.preferredWidth: 32
                                                Layout.preferredHeight: 30
                                                contentItem: Text {
                                                    text: btnBrowseSnapshot.text
                                                    font.bold: true
                                                    color: "white"
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                                background: Rectangle {
                                                    color: btnBrowseSnapshot.pressed ? "#2a3540" : (btnBrowseSnapshot.hovered ? "#3a4550" : "#222c36")
                                                    radius: 4
                                                    border.color: "#2a3540"
                                                }
                                                onClicked: {
                                                     var initial = snapshotPathField.text;
                                                     if (!Context.dirExists(initial)) {
                                                         initial = Context.homePath();
                                                     }
                                                     var selected = Context.selectFolder(qsTr("LNG_00237"), initial);
                                                     if (selected && selected !== "") {
                                                         generalSettings.snapshotPath = selected;
                                                         Context.mkpath(selected);
                                                     }
                                                 }
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Text {
                                            text: qsTr("LNG_00236")
                                            color: "white"
                                            font.pixelSize: 11
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8

                                            TextField {
                                                id: videoPathField
                                                Layout.fillWidth: true
                                                selectByMouse: true
                                                text: generalSettings.videoPath
                                                color: "white"
                                                font.pixelSize: 12
                                                background: Rectangle {
                                                    color: "#0f151b"
                                                    radius: 4
                                                    border.color: videoPathField.activeFocus ? "#ff7a00" : "#2a3540"
                                                }
                                                onEditingFinished: {
                                                    generalSettings.videoPath = text
                                                    Context.mkpath(text)
                                                }
                                            }

                                            Button {
                                                id: btnBrowseVideo
                                                text: "..."
                                                Layout.preferredWidth: 32
                                                Layout.preferredHeight: 30
                                                contentItem: Text {
                                                    text: btnBrowseVideo.text
                                                    font.bold: true
                                                    color: "white"
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                                background: Rectangle {
                                                    color: btnBrowseVideo.pressed ? "#2a3540" : (btnBrowseVideo.hovered ? "#3a4550" : "#222c36")
                                                    radius: 4
                                                    border.color: "#2a3540"
                                                }
                                                onClicked: {
                                                     var initial = videoPathField.text;
                                                     if (!Context.dirExists(initial)) {
                                                         initial = Context.homePath();
                                                     }
                                                     var selected = Context.selectFolder(qsTr("LNG_00235"), initial);
                                                     if (selected && selected !== "") {
                                                         generalSettings.videoPath = selected;
                                                         Context.mkpath(selected);
                                                     }
                                                 }
                                            }
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    CctvButton {
                                        text: qsTr("LNG_00234")
                                        isCeladon: true
                                        Layout.fillWidth: true
                                        onClicked: {
                                            var path = Context.sanitizePlatformPath(generalSettings.snapshotPath, Context.defaultPicturesPath());
                                            Context.openLocalFolder(path);
                                        }
                                    }

                                    CctvButton {
                                        text: qsTr("LNG_00233")
                                        isCeladon: true
                                        Layout.fillWidth: true
                                        onClicked: {
                                            var path = Context.sanitizePlatformPath(generalSettings.videoPath, Context.defaultMoviesPath());
                                            Context.openLocalFolder(path);
                                        }
                                    }
                                }
                            }
                        }

                        GroupBox {
                            title: qsTr("LNG_00232")
                            Layout.fillWidth: true

                            background: Rectangle {
                                color: "#141a21"
                                border.color: "#2a3540"
                                border.width: 1
                                radius: 8
                            }
                            label: Text {
                                text: parent.title
                                color: "#00f5d4"
                                font.bold: true
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: 12

                                CheckBox {
                                    id: activateMediaChangesCheckbox
                                    text: qsTr("LNG_00231")
                                    checked: false
                                    Layout.fillWidth: true
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 12
                                    enabled: activateMediaChangesCheckbox.checked
                                    opacity: activateMediaChangesCheckbox.checked ? 1.0 : 0.5

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Text {
                                            text: qsTr("LNG_00230")
                                            color: "white"
                                            font.pixelSize: 11
                                        }

                                        TextField {
                                            id: defaultAVFormatOptionsField
                                            selectByMouse: true
                                            Layout.fillWidth: true
                                            color: "white"
                                            font.pixelSize: 12
                                            background: Rectangle {
                                                color: "#0f151b"
                                                radius: 4
                                                border.color: defaultAVFormatOptionsField.activeFocus ? "#ff7a00" : "#2a3540"
                                            }
                                            text: {
                                                var opts = "";
                                                var options = layoutsCollectionSettings.toJSValue("defaultAVFormatOptions");
                                                for (var key in options) {
                                                    if (typeof options[key] === "string" || typeof options[key] === "number") {
                                                        opts += "-%1 %2 ".arg(key).arg(options[key]);
                                                    }
                                                }
                                                return opts.trim();
                                            }
                                            onEditingFinished: {
                                                layoutsCollectionSettings.defaultAVFormatOptions = JSON.stringify(Utils.parseOptions(text));
                                            }
                                        }

                                        CctvButton {
                                            Layout.fillWidth: true
                                            isCeladon: true
                                            text: qsTr("LNG_00229")
                                            onClicked: {
                                                var opts = layoutsCollectionSettings.toJSValue("defaultAVFormatOptions");
                                                for (var i = 0; i < layoutsCollectionModel.count; ++i) {
                                                    var layoutModel = layoutsCollectionModel.get(i);
                                                    for (var j = 0; j < layoutModel.count; ++j) {
                                                        var item = layoutModel.get(j);
                                                        if (!item.ignoreGlobalAVFormatOptions) {
                                                            item.avFormatOptions = opts;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        id: page4Section5
                        Layout.fillWidth: true
                        Layout.maximumWidth: 980
                        spacing: 20
                        visible: page4Layout.section === 5

                        CameraToolsPanel {
                            Layout.fillWidth: true

                            GroupBox {
                                title: qsTr("Setup check")
                                Layout.fillWidth: true

                                background: Rectangle {
                                    color: "#141a21"
                                    border.color: "#2a3540"
                                    border.width: 1
                                    radius: 8
                                }
                                label: Text {
                                    text: parent.title
                                    color: "#00f5d4"
                                    font.bold: true
                                    font.pixelSize: 12
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    spacing: 8

                                    SelectableLabel {
                                        text: qsTr("Is each camera set up to report? A read-only check of the camera's settings (metadata, zones, rules, Notify Surveillance Center). It changes nothing.")
                                        textColor: "#8898a6"
                                        font.pixelSize: 11
                                        wrapMode: TextEdit.Wrap
                                        Layout.fillWidth: true
                                    }

                                    CheckBox {
                                        text: qsTr("Check every detection camera once when KVision starts")
                                        checked: generalSettings.checkSetupAtStart
                                        onToggled: generalSettings.checkSetupAtStart = checked
                                        enabled: generalSettings.showTargetIndicator
                                        Layout.fillWidth: true
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Button {
                                            text: qsTr("Check now")
                                            enabled: generalSettings.showTargetIndicator && HikvisionSetupCheck.pending === 0
                                            onClicked: {
                                                rootWindow.checkDetectionSetup("");
                                                var win = setupCheckComponent.createObject(rootWindow, { "focusKey": "" });
                                                if (win)
                                                    win.show();
                                            }
                                        }

                                        Button {
                                            text: qsTr("Show results")
                                            onClicked: {
                                                var win = setupCheckComponent.createObject(rootWindow, { "focusKey": "" });
                                                if (win)
                                                    win.show();
                                            }
                                        }

                                        Text {
                                            visible: HikvisionSetupCheck.pending > 0
                                            text: qsTr("Checking... %1 left").arg(HikvisionSetupCheck.pending)
                                            color: "#8899aa"
                                            font.pixelSize: 11
                                        }
                                    }

                                    Component {
                                        id: setupCheckComponent
                                        SetupCheckWindow {}
                                    }

                                }
                            }
                        }
                    }

                }
            }

            // PAGE 5: Import / Export Settings
            ScrollView {
                id: pageImportExportScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                property string statusMessage: ""
                property bool statusSuccess: true

                ColumnLayout {
                    id: pageImportExportLayout
                    x: 24
                    width: pageImportExportScrollView.width - 48
                    spacing: 16

                    Text {
                        text: qsTr("LNG_00551")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    Text {
                        text: qsTr("LNG_00552")
                        color: "#8898a6"
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    // Status feedback banner
                    Rectangle {
                        visible: pageImportExportScrollView.statusMessage !== ""
                        Layout.fillWidth: true
                        implicitHeight: statusBannerRow.implicitHeight + 20
                        radius: 6
                        color: pageImportExportScrollView.statusSuccess ? "#0d2924" : "#2d1215"
                        border.color: pageImportExportScrollView.statusSuccess ? "#00f5d4" : "#ff4d4d"
                        border.width: 1

                        RowLayout {
                            id: statusBannerRow
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            Text {
                                text: pageImportExportScrollView.statusSuccess ? "✓" : "✕"
                                color: pageImportExportScrollView.statusSuccess ? "#00f5d4" : "#ff4d4d"
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Text {
                                text: pageImportExportScrollView.statusMessage
                                color: "#ffffff"
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // Export GroupBox
                    GroupBox {
                        title: qsTr("LNG_00553")
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 12

                            Text {
                                text: qsTr("LNG_00554")
                                color: "#cccccc"
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }

                            CctvButton {
                                text: qsTr("LNG_00555")
                                isCeladon: true
                                Layout.fillWidth: true
                                onClicked: {
                                    if (typeof rootWindow !== "undefined" && rootWindow && rootWindow.flushSettingsToDisk) {
                                        rootWindow.flushSettingsToDisk();
                                    }
                                    var targetPath = Context.selectExportConfigFile(qsTr("LNG_00555"), Context.defaultPicturesPath());
                                    if (targetPath && targetPath !== "") {
                                        var ok = Context.exportSettings(targetPath);
                                        pageImportExportScrollView.statusSuccess = ok;
                                        pageImportExportScrollView.statusMessage = ok
                                            ? qsTr("LNG_00561").arg(targetPath)
                                            : qsTr("LNG_00563");
                                    }
                                }
                            }
                        }
                    }

                    // Import GroupBox
                    GroupBox {
                        title: qsTr("LNG_00556")
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 12

                            Text {
                                text: qsTr("LNG_00557")
                                color: "#cccccc"
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }

                            CctvButton {
                                text: qsTr("LNG_00558")
                                isCeladon: true
                                Layout.fillWidth: true
                                onClicked: {
                                    var sourcePath = Context.selectImportConfigFile(qsTr("LNG_00558"), Context.configDirPath());
                                    if (sourcePath && sourcePath !== "") {
                                        var ok = Context.importSettings(sourcePath);
                                        pageImportExportScrollView.statusSuccess = ok;
                                        pageImportExportScrollView.statusMessage = ok
                                            ? qsTr("LNG_00562").arg(sourcePath)
                                            : qsTr("LNG_00563");
                                    }
                                }
                            }
                        }
                    }

                    // Active config file info GroupBox
                    GroupBox {
                        title: qsTr("LNG_00559")
                        Layout.fillWidth: true

                        background: Rectangle {
                            color: "#141a21"
                            border.color: "#2a3540"
                            border.width: 1
                            radius: 8
                        }
                        label: Text {
                            text: parent.title
                            color: "#00f5d4"
                            font.bold: true
                            font.pixelSize: 12
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 10

                            TextField {
                                id: activeConfigPathField
                                readOnly: true
                                selectByMouse: true
                                Layout.fillWidth: true
                                text: Context.config.fileName
                                color: "#8898a6"
                                font.pixelSize: 11
                                background: Rectangle {
                                    color: "#0f151b"
                                    radius: 4
                                    border.color: activeConfigPathField.activeFocus ? "#00f5d4" : "#2a3540"
                                }
                            }

                            CctvButton {
                                text: qsTr("LNG_00560")
                                isCeladon: true
                                Layout.fillWidth: true
                                onClicked: {
                                    var dirPath = Context.configDirPath();
                                    Context.openLocalFolder(dirPath);
                                }
                            }
                        }
                    }
                }
            }

            // PAGE 6: Changelog
            ScrollView {
                id: page5ScrollView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    id: page5Layout
                    x: 24
                    width: page5ScrollView.width - 48
                    spacing: 20

                    Text {
                        text: qsTr("LNG_00228")
                        color: "#00f5d4"
                        font {
                            pixelSize: 16
                            bold: true
                        }
                    }

                    Text {
                        text: qsTr("LNG_00227")
                        color: "#8898a6"
                        font.pixelSize: 13
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    // Repeater rendering each version entry beautifully
                    Repeater {
                        model: rootSideBar.changelogData
                        delegate: ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Layout.bottomMargin: 16

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: modelData.version
                                    color: "#00f5d4"
                                    font {
                                        pixelSize: 14
                                        bold: true
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: modelData.date
                                    color: "#8898a6"
                                    font.pixelSize: 12
                                }
                            }

                            // Divider line
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#2a3540"
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Layout.leftMargin: 8

                                Repeater {
                                    model: modelData.changes
                                    delegate: RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            text: "•"
                                            color: "#00f5d4"
                                            font.pixelSize: 14
                                            Layout.alignment: Qt.AlignTop
                                        }
                                        Text {
                                            text: modelData
                                            color: "#eeeeee"
                                            font.pixelSize: 12
                                            wrapMode: Text.WordWrap
                                            Layout.fillWidth: true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    LayoutBackupDialog {
        id: layoutBackupDialog
        onClosed: rootSideBar.refreshDeletedBackups()
    }
    Connections {
        target: LayoutBackups
        function onChanged() { rootSideBar.refreshDeletedBackups(); }
    }

    // Asked when a layout that has backups is deleted
    Dialog {
        id: keepBackupsDialog
        modal: true
        anchors.centerIn: parent
        width: 460
        leftPadding: 16; rightPadding: 16; topPadding: 16; bottomPadding: 16
        property int index: -1
        property var target: index >= 0 && index < layoutsCollectionModel.count ? layoutsCollectionModel.get(index) : null
        property int backups: target ? LayoutBackups.count(target.uid) : 0
        property string layoutName: (target && target.name && target.name.trim() !== "") ? target.name : qsTr("this layout")

        background: Rectangle { color: "#1c242c"; border.color: "#2a3540"; radius: 8 }
        header: Rectangle {
            color: "#0f151b"; implicitHeight: 42; radius: 8
            Text { anchors.fill: parent; anchors.leftMargin: 16; text: qsTr("What about the backups?"); color: "#00f5d4"; font.bold: true; font.pixelSize: 13; verticalAlignment: Text.AlignVCenter }
        }
        contentItem: Text {
            wrapMode: Text.Wrap
            color: "white"
            font.pixelSize: 12
            text: qsTr("%1 has %2 saved backup(s). The layout is about to be deleted.\n\nKeep the backups and you can bring it back later with \"Recover a deleted layout\". Delete them too and it cannot be recovered.").arg(keepBackupsDialog.layoutName).arg(keepBackupsDialog.backups)
        }
        footer: Rectangle {
            implicitHeight: 52
            color: "#0f151b"
            radius: 8
            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    id: kbCancel
                    text: qsTr("Cancel")
                    implicitWidth: 80; implicitHeight: 32
                    contentItem: Text { text: kbCancel.text; color: "white"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: kbCancel.hovered ? "#3a4550" : "#222c36"; radius: 4; border.color: "#2a3540" }
                    onClicked: keepBackupsDialog.close()
                }
                Button {
                    id: kbDelete
                    text: qsTr("Delete them too")
                    implicitWidth: 130; implicitHeight: 32
                    contentItem: Text { text: kbDelete.text; color: "white"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: kbDelete.hovered ? "#ff4d4d" : "#d63333"; radius: 4 }
                    onClicked: { var i = keepBackupsDialog.index; keepBackupsDialog.close(); rootSideBar.finishDelete(i, "delete"); }
                }
                Button {
                    id: kbKeep
                    text: qsTr("Keep the backups")
                    implicitWidth: 140; implicitHeight: 32
                    contentItem: Text { text: kbKeep.text; color: "#0f151b"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: kbKeep.hovered ? "#00ffd8" : "#00f5d4"; radius: 4 }
                    onClicked: { var i = keepBackupsDialog.index; keepBackupsDialog.close(); rootSideBar.finishDelete(i, "keep"); }
                }
            }
        }
    }

    // Modal dialogs declared safely at root scope
    ConfirmDialog {
        id: presetDeleteDialog
        title: qsTr("LNG_00222")
        iconSource: "qrc:/images/icon-trash.svg"
        message: {
            if (index >= 0 && index < layoutsCollectionModel.count) {
                var layout = layoutsCollectionModel.get(index);
                if (layout && layout.name && layout.name.trim() !== "") {
                    return qsTr("LNG_00226").arg(layout.name);
                }
            }
            return qsTr("LNG_00225").arg(index + 1);
        }
        property int index: -1
        onAccepted: rootSideBar.deleteLayoutAt(index)
    }

    Connections {
        target: generalSettings
        function onSnapshotPathChanged() {
            snapshotPathField.text = generalSettings.snapshotPath;
        }
        function onVideoPathChanged() {
            videoPathField.text = generalSettings.videoPath;
        }
        function onAuxiliaryLimitChanged() {
            auxiliaryLimitField.text = generalSettings.auxiliaryLimit.toString();
        }
        function onAuxiliaryScaleChanged() {
            auxiliaryScaleBox.currentIndex = rootSideBar.auxiliaryScaleIndex();
        }
    }


}
