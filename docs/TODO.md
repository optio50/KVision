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

### 4. [x] "Check detection setup" for a camera (done, not yet committed; fixes are the next step)
- **Why:** on 10 Nov nearly every "no events" problem was a setting in the camera or recorder: metadata off, a rule
  switched off, no centre action, no zone drawn, a switch that did not save. Their README says the same: "For NVR/DVR,
  remember to select Notify Alarm Center... otherwise the NVR won't emit any alarm event."
- **Idea:** a right-click item that reads (read-only) and lists what is missing for that camera. The reads are listed in
  `docs/AUDIT-2026-11-10.md`, section "Reads that answer 'why no events'".
- **Never changes anything.** It only reports.
- **Done when:** run on Garage3 as it was before the fixes, it names metadata, the rule switches and the centre action.

### 5. [x] Keep the picture that comes with an event (done, not yet committed)
- **Done so far:** the setup check reports whether event pictures carry the rule and target frames (tested on Garage3's
  real pictures: frame on = outline found on the reported rectangle, frame off = none). Pictures are not kept yet.
- **Not possible:** reading or setting the camera's "Overlay Rule Frame and Target Frame" switch over ISAPI. It is not
  in any of about 70 settings paths tried; it is only in the camera's web page.
- **Why:** both the recorder's SDK alarm and the camera's own stream attach a snapshot with the box drawn on it (about
  250 KB). Their node passes it on (`picName`, `picUrl`, the image output).
- **Idea:** keep the latest picture per camera, show it in the detection log window next to the entry, and store a
  small copy beside the log. Needs a size limit and a clean-up so the folder cannot grow without end.
- **Where:** `src/hikvisionevents.cpp` (the stream parser currently throws the picture parts away),
  `src/DetectionLogWindow.qml`.
- **Done when:** a log entry shows the picture from that moment.

## Left over from 10 Nov 2026 (see the audit trail)

- [~] **Release the source and event-type filters.** Committed (`99bc238`), with README and changelog entries.
      Only tested against a fake recorder and by checking numbers. Try it on the real NVR with a screen, then bump
      the version and make a release.
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

## Added 12 Nov 2026 (see section 10 of the audit trail)

- [ ] **Camera settings window: test it fully** (layout, week strips, the all-cameras table and both copy buttons). The
      reading code was tested from the command line only.
- [ ] **Linked events: say "could not be read" when the recorder does not answer.** One run showed "nothing on the
      recorder is linked" for the Front Door's audio because the recorder dropped the answer.
- [ ] **Image Parameters Switch:** the scene that is selected on a "Not Switch" camera is not in
      `/ISAPI/Image/channels/1/displayParamSwitch`; where it lives is unknown. Cabin Inside, DoggieCam and the Doorbell
      do not offer the request at all.
- [ ] **Restore:** only tested on DoggieCam, and only the device name was checked afterwards. Try one more camera and
      compare more settings (before a restore, take the safety backup it makes, and keep it).
- [ ] **Face detection on Livingroom2 / Garage2 (192.0.0.108):** enabled on the camera, but no face event appeared on its
      stream or the NVR's in two live tests. `OtherEvents.log` would show one if it ever came. Unknown whether this model
      sends one.
- [ ] **Audio at the Front Door does not sound by day.** The likely cause is the camera's own audible alarm hours
      (00:00-05:45, 21:00-24:00). Not tested by triggering the event by day and by night. The other cameras with limited
      hours are in the all-cameras table (orange).
- [ ] **Four NVR rules that flash lights are switched off:** Pano region entrance, FrontDoor line crossing, PTZ intrusion,
      Driveway line crossing. Decide whether they should be on.
- [ ] **Watch `logs/OtherEvents.log` for a while** to see which event types the cameras send that KVision does not know.
      `IO` and `duration` are skipped on purpose. Tamper types were left out on purpose.
- [ ] **Old camera quirk:** Cabin Inside (192.0.0.11, firmware V5.4.800) returns a configuration export even without a key,
      so its file may not be encrypted. Treat it as sensitive.

## Ideas not taken from the Node-RED project (on purpose)

- Alarm panel, doorbell, speaker and access-control nodes: outside what KVision is for.
- Network discovery of devices by multicast: KVision adds recorders by address, and we do not want to scan the network.
- Licence-plate recognition: only worth it if a plate camera is added.
- Other events on the same stream (tamper, defocus, scene change, video loss, storage errors, temperature): worth a
  look later as a separate "camera problem" frame.
- From reading other Hikvision projects (12 Nov): automatic discovery of devices on the network (SADP), and a warning
  when a camera's clock is more than a few minutes off (digest login fails). Neither done.
