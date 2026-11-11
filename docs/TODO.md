# KVision to-do list

Written 10 Nov 2026. Items 1 to 5 come from reading the Node-RED project
[Supergiovane/node-red-contrib-hikvision-ultimate](https://github.com/Supergiovane/node-red-contrib-hikvision-ultimate)
(MIT licence), which also reads Hikvision event streams. We take ideas from it, not code. Its README, changelog and
a few source files were read; its whole code base was not reviewed.

Status key: `[ ]` not started, `[~]` started, `[x]` done.

## From the Node-RED project

### 1. [ ] Drop stale reports from the screen
- **Why:** after a stall or a reconnect a camera can send a backlog. Today a late report still flashes a frame, and only
  the log line is marked `received HH:mm:ss`. On 10 Nov a burst of 68 log lines landed in one second.
- **Idea:** do not show a frame for a report whose camera time is more than about 10 seconds old. Still write it to the
  log. Their changelog (version 1.4.0) filters backlog events by `dateTime` and caps each batch.
- **Where:** `src/hikvisionevents.cpp`, in the same place the "late" test for the log already lives (`logDetection`).
- **Done when:** a replayed old report does not show a frame, and the log still has it.

### 2. [ ] Optional merge of duplicate reports
- **Why:** the same event can arrive twice. Garage3 sent two line crossings in the same second and we could not tell a
  real second crossing from a repeat. Their changelog mentions duplicates from the same event arriving twice.
- **Idea:** a short window (for example 1 second) in which an identical report for the same camera, kind and target is
  merged. Make it a setting and leave it off by default, because every real crossing matters for the interval study.
- **Done when:** the setting exists and, switched on, two identical reports in the window give one frame and one line.

### 3. [ ] "Detection offline" mark on a tile
- **Why:** a quiet camera and a dead connection look the same on screen today.
- **Idea:** their Device Status node reads `GET /ISAPI/System/deviceInfo` every 30 seconds, marks a device offline after 2
  failed checks, and backs off for 30 seconds after HTTP 401, 403, 429 or 503. Do the same for the connection a tile
  uses, with a small mark on the tile. Keep our rule never to send a login we know is wrong (a wrong password can lock a
  camera).
- **Where:** `src/hikvisionevents.cpp` (the connection already counts failures and has `listenFailed`) and `src/Player.qml`.
- **Done when:** unplugging a camera shows the mark within about a minute, and plugging it back in clears it.

### 4. [ ] "Check detection setup" for a camera
- **Why:** on 10 Nov nearly every "no events" problem was a setting in the camera or recorder: metadata off, a rule
  switched off, no centre action, no zone drawn, a switch that did not save. Their README says the same: "For NVR/DVR,
  remember to select Notify Alarm Center... otherwise the NVR won't emit any alarm event."
- **Idea:** a right-click item that reads (read-only) and lists what is missing for that camera. The reads are listed in
  `docs/AUDIT-2026-11-10.md`, section "Reads that answer 'why no events'".
- **Never changes anything.** It only reports.
- **Done when:** run on Garage3 as it was before the fixes, it names metadata, the rule switches and the centre action.

### 5. [ ] Keep the picture that comes with an event
- **Why:** both the recorder's SDK alarm and the camera's own stream attach a snapshot with the box drawn on it (about
  250 KB). Their node passes it on (`picName`, `picUrl`, the image output).
- **Idea:** keep the latest picture per camera, show it in the detection log window next to the entry, and store a
  small copy beside the log. Needs a size limit and a clean-up so the folder cannot grow without end.
- **Where:** `src/hikvisionevents.cpp` (the stream parser currently throws the picture parts away),
  `src/DetectionLogWindow.qml`.
- **Done when:** a log entry shows the picture from that moment.

## Left over from 10 Nov 2026 (see the audit trail)

- [ ] **Commit the source and event-type filters.** The code is in the working tree and only tested against a fake
      recorder. Try it on the real NVR first. Then add a README note, a changelog entry and a version bump.
- [ ] **Find out why the "NVR cameras switched on" list emptied itself** (`targetNvrOnCameras=[]` appeared in the
      saved configuration). Best guess: one of the offscreen test runs of the app saved an empty list. Not proven.
      It was restored by hand to 14 cameras. If it empties again, look at how the settings are written on exit.
- [ ] **Decide what to do with the temporary centre action on Garage3 (NVR channel 17).** The backups hold the
      "record only" originals. See the audit trail for how to put them back.
- [ ] **Livingroom2 (NVR channel 18)** has no smart detection set up and is a different model. Not touched.
- [ ] **Doorbell (192.168.20.185)** did not answer the device-type questions, so how KVision classifies it is untested.
- [ ] **Dual-lens camera (Cabin PTZ, two lenses on one connection):** whether each lens reports with its own channel
      number was never watched. Test it.
- [ ] **A DVR (analogue recorder)** was never tested; none is available.
- [ ] **Check the Target Validity setting on Garage3.** It was changed to High in the camera's page, but a read-back
      of the line rule showed `mediumLow`. Unconfirmed.
- [ ] **Interval study:** the question "does the camera pause between reports" is not settled. Test with a counted
      series of crossings through both the camera and the recorder at once. See the audit trail, "Open questions".
- [ ] **Tidy up** `/tmp/evprobe`, `/tmp/vcalive`, `/tmp/nvrlive`, `/tmp/g3live`: probe programs and logs from 10 Nov.
      They disappear when the machine restarts. Copy anything worth keeping first.

## Ideas not taken from the Node-RED project (on purpose)

- Alarm panel, doorbell, speaker and access-control nodes: outside what KVision is for.
- Network discovery of devices by multicast: KVision adds recorders by address, and we do not want to scan the network.
- Licence-plate recognition: only worth it if a plate camera is added.
- Other events on the same stream (tamper, defocus, scene change, video loss, storage errors, temperature): worth a
  look later as a separate "camera problem" frame.
