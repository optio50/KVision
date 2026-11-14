# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
* **Rule lines on the video stream can be switched on and off from Camera Tools.** A new "Rule lines on the video stream" box
  picks a camera and has Check, Turn on and Turn off. It is the camera's own switch (web page: VCA > Smart Event > General
  Settings > Metadata > Enable Stream Rule and Sub-Stream, which work as a pair), so the camera draws its line, intrusion and
  region rules on the stream, including the sub-stream the small tiles use. It reads the camera first, changes only
  `enabled` and `streamType` (the separate "Overlay Rule Frame on Background Picture" switch is written back as it was), and
  reads the camera again to confirm. A camera without the switch says so. It uses the camera's own address and saved login,
  never the recorder's, and a refused login is not tried again. Recorders set Offline are not listed.
  "Check all", "Turn on all" and "Turn off all" do the same for every camera in the list, one after the other, after a
  confirmation. Cameras that cannot take the switch are skipped and counted, and a login that one camera refused is not sent to
  another camera. A camera that answers a read but lists the setting as "notSupport" in its capabilities (the panoramic
  cameras) is counted as having no switch, not as a failure. (A recorder itself has no such switch over the network; its own screen menu button is not reachable.)

### Changed
* **A recorder can be set "Offline" when its network is not connected.** The "Mute" box in the recorder monitoring window is now
  "Offline". Ticked, KVision makes no connection at all to that recorder's cameras: no video (its tiles say "Offline by
  choice"), no detection events, no logging (also in the background `kvision-events` service) and no status check (the
  recorder shows a grey OFFLINE badge, not an error). Unticking it connects again straight away. Recorders already muted
  keep that setting, so they are now offline as well. The terminal prints an `[Offline]` line when you change it.
* **The setup check no longer shows red for a camera that works.** A camera is red only when it cannot report detection (it
  is unreachable, the login is refused, or nothing is set up to report). When at least one kind of detection works and a single
  feature has a fault (motion with no zone drawn, for example), the card is yellow, says "Working, 1 thing(s) to look at", and
  the row says "The camera's other detection still works." Faults that stop everything stay red.
* **The background logger shows its version.** `systemctl --user status kvision-events` now has a `Status:` line such as
  `KVision 3.6.0 GIT.8134301 (x86_64) - logging, watching 24 camera(s)`, the journal's first line says the version, and
  `logs/EventLogger.status` has a `version` field. The commit in the version now follows each new commit, where it
  used to stay at the one from the last full configure.
* **The setup check can judge event pictures straight after start-up, and says what it is asking.** The row is now called
  "Camera outlines the target in its pictures" and answers "Yes." or "No." first, then says which picture it looked at. It
  used to be learned only from a live event, so it read "Not known yet" after every restart; it now also looks at the newest
  pictures already saved for the camera. A "No" explains that KVision draws its own box and zone, so it only matters when the
  pictures are looked at elsewhere. A camera whose events name no rectangle (a line crossing with only a line, for example)
  still reads "Not known yet".
* **Dates are written as "13 Nov 2026".** The Changelog screen, the Download window (the date boxes, which now take
  typing such as "9 Nov 2026"), the Playback window, the Detection events list (no leading zero on the day now), the setup
  check results, the backup list, the recorder status window and every date in the documentation use one form: day,
  three-letter English month, year. The files KVision writes for itself (the detection log, `SetupCheck.log`, picture and
  backup file names) and everything sent to or read from a recorder or camera keep their own formats.
* **A new "Camera Tools" tab in Settings.** Camera backup (with restore and the read-only camera settings window), the Setup
  check and Troubleshooting (unstick event detection) are together on one page, in that order. They moved from the NVR tab
  (backup and troubleshooting) and the Detection tab (setup check). Nothing about how they work has changed.
* **The Recorders screen lines up.** Each recorder's row now keeps the connection status and the five buttons in the same
  columns, however long its name is (a long name is cut short instead of pushing them along), and the three port boxes share
  the row evenly. The rows no longer run past the edge of the boxes around them.
* **Settings are split into sections.** The Settings page was one long column of nine boxes. It now has five tabs: *Detection*
  (the frame, where events come from, unlabelled motion, the log and pictures, and the setup check), *NVR* (status monitoring),
  *Cameras and display* (the right-click menu, on-screen badges, zoom and playback), *Audio*, and *General* (instances,
  diagnostics, the web browser, saving and media). Each section is one short page instead of a long scroll. Nothing moved out of
  Settings, and every choice saves as before.

### Added
* **Choose where each camera's detection events come from.** The *Choose cameras* window (detection settings) now has a
  *Reports: camera / NVR* choice for every camera behind a recorder, and *All from camera* / *All from NVR* for a whole
  recorder. A camera can take its events from its own connection or from the recorder's, and the two can be mixed. Each camera
  is read from one place only, so nothing is logged twice. A camera with no choice of its own follows the general *Event
  source* setting. The background logger follows the same choices. Cameras that are their own recorder are not affected.
* **The detection events window says where each picture came from.** Every new log line ends with `via camera` or `via NVR`:
  the connection the report and its picture arrived on. The picture viewer's caption shows *picture from the camera* or *picture
  from the NVR*, and the picture button's tooltip says the same. The list has a new *Source* column right after the
  address (Camera, or NVR; a dash for older lines) for every entry, since a picture always comes from the device that reported the event, so the window's smallest width is a little larger. Lines written before this
  have no marker and show as before.
* **Motion that names no target can be logged and shown.** Some cameras (a panoramic camera's plain motion zone, for one) report
  that something moved but not what, because their motion detection is not a smart event. KVision kept that off the detection
  log. Two new choices in the detection settings, both off by default: write each movement to the detection log (one line when
  it starts, the next only after 10 seconds without motion, so a recorder's one-a-second repeats do not flood it), and show a
  *MOTION* frame for it on the tile.
* **Hide unlabelled motion in the detection log window.** A new tick box leaves out the motion reports that did not say what
  moved, so the list shows only labelled motion and smart events. It works with the other filters.
* **A picture for labelled motion.** Motion that names a target (human, vehicle, animal or other) is not a smart event and
  brings no picture, so KVision now asks the camera for a still when one is reported: at most one every 30 seconds for each
  camera, so a constant stream cannot fill the disk. These pictures are kept apart from the smart-event ones, with their own
  smaller limit (a quarter of *Pictures kept per camera*), and show in the detection log window like the others. Motion that
  names no target gets no picture.
* **Choose the browser KVision opens web pages in.** A new *Web browser* box in General settings picks the browser used for
  every page KVision opens: a camera's own page (right-click *Open Web UI*, the globe button on a recorder, the setup check)
  and the project's links. It lists the browsers installed here (from their launcher files) or takes a command of your own
  (`%u` is where the address goes), with a *Test* button. The chosen browser is started directly, so it is used even when
  another browser is already open; a browser that is already running just opens a new tab. Only http and https addresses are
  opened, the address is passed as one argument and never through a shell, and a browser that cannot be started falls back to
  the system default. The default is *System default*, so nothing changes until you choose.

### Changed
* **Safer settings file.** KVision keeps one copy of the settings file per day (`KVision.conf.daily-YYYY-MM-DD`, the last 14
  days) as well as the `.bak` copy that is replaced at every start. A new start also waits up to 10 seconds for a previous
  window that is still shutting down, so two windows do not write the same settings file at once.

### Fixed
* **Detection events window: the controls are no longer pushed off the edge.** A long camera name in the *Only this camera*
  box, or a long notice at the bottom, used to widen the window's contents so *Refresh* and *Load 10 more* ended up past the
  right edge. Both now shorten with "..." (the notice shows in full on hover), and the window cannot be made narrower than
  its controls need.
* **The event picture viewer no longer draws its own target box on a picture the camera already framed.** A camera reports a
  target several times a second while it is still classifying it (first "Other", then "Animal"), each time with a moving
  box, and one picture file serves all of those log lines. The viewer judged the picture only by the box of the row that
  was clicked, so an "Other" row, whose box was not the one the camera drew, got extra boxes drawn on a correctly framed
  picture. It now judges the picture by every box logged for it, and draws nothing if any of them sits on the camera's
  red outline.

## [3.6.0] - 12 Nov 2026

### Added
* **Detection events window shows which entries still have video.** When the window opens, KVision asks each recorder
  (and each camera that records on its own) for its oldest recording: one small search per camera, on a background
  thread, and not repeated within ten minutes. An entry older than that gets a dimmed play button and a tooltip saying the
  recorder no longer has video from that time; double-clicking it still tries and says playback may be empty. If a camera
  cannot be asked, nothing is dimmed. Only the oldest recording is compared, not gaps in the middle.
* **Camera settings window (read only).** A new *Camera settings (read only)...* button in NVR settings opens a window that
  reads one camera's own settings on its own address: device and firmware, time and network, video streams, picture
  settings, the detection rules and what each one does on the camera, the hours of its speaker (audible alarm) and white
  light as a 7 day strip, memory card, recording and users (names only). A section a camera does not offer is left out, so
  older cameras show less. *All cameras* reads every camera one after the other into one table (model, firmware, audio and
  light hours, motion, intrusion, line crossing); hours that are not all day are shown in orange, since an NVR action only
  runs inside the camera's own hours. *Copy as text* copies one camera's settings. Nothing in it can change a camera.
  The table also names which cameras trigger each camera's speaker and light (from the recorder's event rules, with
  switched-off events marked) and has *Copy table as text*, tab separated for a spreadsheet. The Image section shows the
  *Image parameters switch* (Not Switch, Scheduled-Switch with the scene now and this month's schedule, or a PTZ's timing
  switch) and the picture values read from the right place. The detection actions are written in plain words.
* **Larger donate button in the README** (`images/donate.svg`), replacing the small badge.
* **Other events log.** An event a camera sends that KVision has no kind for (a face event, the `duration` "stayed in the
  area" report, anything new) used to be dropped without a trace. It is now written to `logs/OtherEvents.log` with the
  camera's own type name and the start of its message, so unknown events can be seen. A line is written when an event's
  state changes and at most every ten minutes while it stays the same. The camera heartbeat, `IO` (an input port changed)
  and `duration` (the follow-up to a field detection) are left out, as they say nothing new. The file is
  kept under 2 MB (one older copy). It is also written by the background logger.
* **Camera backup.** A new *Camera backup* section in NVR settings saves a camera's own configuration (its
  `/ISAPI/System/configurationData` export) to `backups/` next to the config file, with a small `.json` beside it (name,
  model, firmware, serial, date). *Back up* does the picked camera; *Back up all cameras* does every camera one after the
  other in the background, with a progress notice and a summary. Every camera is reached on its own address: a camera
  behind a recorder is found through the recorder's channel list, but the recorder itself is never backed up. A camera uses
  the recorder's login unless you give it its own username and password, which are kept for that camera once it accepts
  them. One login attempt per camera, never a blank password. A camera that does not report its details (an old doorbell)
  is skipped with a note. The files are readable only by you. The export key is built in, so there is nothing to type, and
  it must never be changed or older backups cannot be restored. *Restore* puts a chosen backup back on the camera it came
  from only: the serial number must match, a fresh backup of the camera is taken first, and nothing is sent if that fails.
  It then uploads the file, waits for the camera to restart and checks that it answers again. One camera at a time, after
  two confirmations.
* **Detection logging is separate from the on-screen frame, and can keep running after KVision is closed.** While KVision
  is open it now always logs every configured camera, whether or not a tile shows it. The global frame setting and the
  right-click *Detection frame* switch only decide what is drawn. A new *Keep logging detection events after KVision is
  closed* option in General settings controls what happens when the window closes. Turning it on installs a small systemd user service (`kvision-events.service`,
  running `kvision --headless-events`: no window, no video) that keeps the detection log and pictures going while KVision is
  closed. It steps aside while a KVision window is open (the window holds `kvision-ui.lock`), so only one of them holds a
  camera's event stream. It watches itself: dead streams are reopened, systemd restarts it if it hangs, and it writes
  `logs/EventLogger.status`, which the settings page shows as a one-line health summary. A second toolbar icon (green, or
  red and pulsing like the recorder one when the service is down, hung or a camera stream is dead) opens a menu with the
  problem and a *Restart background logging* action; while KVision is open it restarts the service by itself when it is down or hung (checked every 10 s, two bad
  readings in a row, backing off from 1 to 10 minutes if it keeps failing) and says so in a notice; opening KVision also
  restarts a service that was stopped. Off by default (with it off, nothing is logged while KVision is closed). Cameras
  that were switched off for the frame are now logged too while KVision is open.
* **Check again from the setup check window.** The window's *Refresh* button now asks the cameras again (it used to only
  re-read the saved results, so nothing seemed to happen): it checks every camera in the list. Each opened card also has
  a small *Check this camera again* button that checks only that one camera, and both wait while a check is running.
* **The setup check lists every kind of rule the camera offers.** A line crossing, intrusion, region entrance or region
  exit rule that is switched off with nothing drawn used to be left out of the card, which hid an intrusion rule that
  someone expected to be on. It is now listed in grey with a dash, "Switched off, and no line or area is drawn.", and
  is not counted as a problem. A kind the camera does not offer at all is still left out.
* **Open the camera's web page from the setup check.** Each camera's card in the detection setup check, once opened, has
  an *Open camera web page* button, the same as the tile's right-click *Open camera web UI*. For a camera behind a
  recorder it opens the camera's own address, as found by the check.
* **The statistics panel keeps its history.** The CPU, GPU and network charts used to start from zero every time the
  panel was opened, and everything collected while it was closed was thrown away. The samples (one a second, the same
  full numbers an open panel shows) are now kept in a rolling buffer, and the charts open with the whole window drawn.
* **History length.** A small button in the panel's title bar steps the kept window through 5, 15, 30 and 60 minutes;
  the choice is saved with the settings, a longer window is averaged down to the charts' slots, and closing the panel
  no longer clears it.
* **Streams and decode counters in the statistics panel.** Two new lines in the panel: the number of live FFmpeg streams
  and Hikvision SDK playback sessions that are open right now, and — added up since KVision started — the frames thrown
  away because a decoder's queue was full, and the demux or decode hiccups that were seen. The CPU line also names the
  machine's busiest core, and on NVIDIA the GPU line names the decode engine's load. All of them are part of the kept
  history too.
* **Unstick event detection button in NVR settings.** A new "Troubleshooting" section in the NVR settings panel with
  a camera picker and "Unstick event detection" button. When clicked, it toggles the \"center\" (Surveillance Center / LAN
  push) notification method off and back on for every event trigger of the selected camera or NVR channel (motion, line
  crossing, intrusion, tamper, ...), restoring the original config. This fixes
  a wedged event-detection dispatcher that accepts connections and heartbeats but delivers zero detection events.

### Fixed
* **CPU read zero.** The per-core reading reads `/proc/stat` with an until-end-of-file loop — but `/proc` files report a
  size of zero, so the loop stopped before reading a single line and the CPU chart flatlined at 0%. The file is now
  read until `readLine()` says the end; the CPU (and the busiest-core line) work again.
* **The AMD/Intel GPU reading never worked.** The same end-of-file pitfall sat in the DRM client-stats fallback, which
  reads `/proc/<pid>/fdinfo` — inherited from upstream, the loop never read a line, so a graphics card that is not
  NVIDIA always showed 0%. Such a card can now show its real load, when its driver exposes drm-engine stats.
* **Detection events filter.** "All types" now really means everything: plain labelled Motion events are included in
  that list instead of requiring their own filter choice. Choose "Motion" to see only those.

## [3.5.0] - 12 Nov 2026

### Added
* **Overlay text from MQTT.** A new *Overlay text from MQTT...* button in the settings (under the detection options) opens a
  window that shows a value from an MQTT broker, such as an outside temperature, in one of a camera's on-screen text
  overlays, and refreshes it every few minutes (5 by default). Choose the broker, port and topic (user and password if
  needed), the name of the number when the message is JSON such as `{"value": 1.5}`, the camera and which of its four text
  overlays to use, the text (for example `Outside {temp} {unit}`), Celsius or Fahrenheit, and the number of decimals. The
  value is taken as Celsius and converted when Fahrenheit is chosen. A *Test* button shows the text it would write
  without writing anything. Off by default and only runs while KVision is running. It is the one place KVision writes to
  a camera, so it is careful: it reads the camera's overlay first and changes only the text of the chosen slot (and
  switches that slot on if it was off), writes only when the text has changed, reads it back to check, tries the login
  once and stops for the session if it is refused, and never retries in a loop. The broker is read with a small built-in
  MQTT client (one connect, subscribe, first message, disconnect), so no extra package is needed. Plain MQTT without TLS
  only. Cameras behind a recorder are offered too (written through each channel's own address), and no camera is
  chosen until you pick one: Save refuses while the box is ticked without a camera. If the chosen text overlay is not in the
  camera's list (these cameras leave an unused one out), KVision adds it, which the Pano accepted; an overlay that is
  switched off is switched on. The text of the chosen slot is replaced.
  A *Remove from camera* button takes the chosen text overlay off the camera again (after asking), by switching it off and
  emptying its text, which these cameras take as "delete this entry", and switches the updates off, so nobody has to log
  in to the camera to get rid of it. Tested on the DT387G2P Pano (NVR channel 12) with the temperature topic of a Victron system.
* **Target box and zone drawn on event pictures that have no frame.** Some cameras (the wide-angle Pano has no switch for
  it) save event pictures without the red target frame, which makes it hard to see what set the camera off. Each new
  smart-event line in `Detection.log` now ends with where the camera said the target was (`box`), which zone fired
  (`zone`) and the zone's corners (`poly`). In the Detection events picture viewer, a picture that the camera did not
  frame itself gets a red box on the target and an orange outline of the zone, and the caption shows the zone number,
  for example "Intrusion (zone 1)". A picture that already has the camera's own frame is left as it is. A tick box,
  "Target and zone", hides the drawing. It applies to events logged from now on; older lines have no position.
* **Save the picture you are looking at.** The Detection events picture viewer has a camera button (or press S) that
  saves the picture on screen in the snapshot folder from the settings, in a folder for the day, named like the
  snapshots of a live tile (channel, camera, date and time) with the kind of event added, for example
  `14_NVR_Ch._14_PTZ_2026-11-11_143337_Linecrossing.jpg`. The same "Snapshot saved" box with a folder button appears.
  The time in the name is the event's time from the log.
* **Search the detection events by type.** A new type list in the Detection events window picks line crossing,
  intrusion, region entrance, region exit, tracking, motion or the other smart events, and it works together with the
  time range and the target. It replaces the "Plain motion" box: "All types" still leaves out plain motion, and choosing
  "Motion" lists it.
* **Search the detection events by time and target, across all cameras.** The Detection events window has a time range
  (last hour, 3, 12 or 24 hours, today, yesterday, last 7 days or all time), a target (human, vehicle, animal, other)
  and a "Plain motion" box, and shows how many events match, for example "124 events". The list is one list across all
  cameras, newest first, with the picture and play buttons and the picture viewer's arrows as before. Plain labelled
  motion is left out unless the box is ticked, because there are many more of those and they have no picture. The
  search reads the detection log, so it covers only the times KVision was running with detection on.
* **5-second jump buttons in playback.** A "5" rewind and a "5" forward button join the 15, 45 and 60 second ones, next
  to the play/pause button.

### Changed
* The launcher no longer prints Qt's "QML ToolTip: Binding loop detected for property implicitWidth" warning, which Qt
  gives each time a wrapped tooltip appears and which is harmless. It is still shown with `kvision --verbose`.
* **A track now keeps four snapshots, the first taken at once.** The first snapshot no longer waits a second after the
  PTZ leaves its park position, and three more follow, one a second apart. Each is named by the second it was asked
  for, so a slow reply cannot make two of them share a file. The first may show the PTZ still swinging.

### Documentation
* The README explains that the 1x1, 2x2 and similar top bar grids are temporary, are never saved, and go away when you
  click a saved layout.

## [3.4.0] - 11 Nov 2026

### Added
* **The picture viewer steps through the whole list.** Click the Picture button on any entry and the viewer opens on that
  picture; the right arrow (or the Right key) always goes to the next newest picture and the left arrow to an older one,
  skipping entries with no picture, with a counter such as "7 / 25" and each picture's own time, target and kind above
  it. A tracking entry's snapshots run oldest to newest. It covers the entries loaded in the window, so press "Load 10 more" first to
  reach older ones.
* **Playback timelines also show what the detection log holds.** The recorder saves fewer smart events than a camera
  reports (the PTZ close-up's events were mostly missing), so the timeline now adds the line, intrusion, entrance, exit
  and other events from `Detection.log` for that camera and channel. Events that only the log has are drawn as a thin
  strip in the lower half of the bar, with a note in the legend. A logged event is left out when the recorder has the
  same kind within 3 seconds. A logged event is drawn only where the bar shows video, so a recorder that records only
  on events or motion shows no tick that leads to nothing. This covers only the times KVision was running with
  detection on.
* **A PTZ that follows a target shows TRACKING on its tile.** A two-lens PTZ (close-up plus wide view) is told where to
  point by the wide lens, and the close-up itself sends no line or intrusion report while it follows. The camera does
  say when the close-up leaves its park position ("leave"), where it points about once a second, and when it is back.
  KVision now reads those messages. While the close-up follows, its tile shows an amber frame with the target the wide
  lens named, for example "HUMAN - TRACKING", and clears it when the camera is back at its park position or stops
  sending positions. No frame is shown if the wide lens named nothing in the last 15 seconds (someone steering the
  PTZ by hand), and a report the close-up makes itself is never replaced.
* **A track is logged with two snapshots a second apart.** When the PTZ starts to follow a target, the detection log gets
  a "Tracking" line (target from the wide lens, camera and recorder channel of the PTZ lens), and KVision takes two
  snapshots of the PTZ lens one and two seconds later, from the camera's own picture address with the same login. The
  Picture button on that line opens a viewer with arrows to step between them. One snapshot request at a time, and a
  refused login stops them. Not taken for cameras read through the recorder.
* **Playback timeline ticks are coloured by what the recorder says the event was.** Before, every event was red. Now
  motion is yellow, line crossing red, intrusion magenta, region entrance blue, region exit purple and any other smart
  event grey, with a small legend at the top right of the timeline showing the kinds that are drawn. The 30-minute bar
  on a live tile uses the same colours. The kind comes from the recorder's saved-event search (motion, line crossing and
  field detection are separate there). The recorder does not say who crossed, so there is no human / animal colour.

### Fixed
* **Events of different kinds in the same second keep their own pictures.** A camera can report a line crossing, a region
  entrance and an intrusion in one second, each with its own picture, but the pictures were named only by camera and
  second, so the last one overwrote the others and every log line showed the same picture. The kind is now part of the
  file name (for example `192.0.0.115_ch15_1794430690-linecrossing.jpg`). Pictures saved before still open. Two events
  of the same kind in the same second still share one picture.
* **The two lenses of a PTZ keep their event pictures apart.** Both lenses share one address, so their pictures shared
  one file name and one could overwrite the other when both fired in the same second. A two-lens camera's pictures are
  now named `<address>_ch<recorder channel>_<time>.jpg` (for example `192.0.0.115_ch14_...`). Other cameras keep their
  names, and pictures saved before still open. The per-camera limit counts each lens on its own.
* **A camera with two lenses (a PTZ with a close-up and a wide view) now logs and shows each lens as its own camera.**
  The camera names the lens in every report on its one stream (channel 1 or 2). KVision ignored that number, so the
  detection log named every event after whichever tile opened the connection first (all of them "Ch. 14 PTZ", none for
  the wide view), "Play" from the log opened the wrong lens, and both tiles flashed a frame for either lens. Now the log
  line carries the right camera name and recorder channel, and a tile shows only its own lens's reports. This covers a
  two-lens camera on its own and one behind a recorder (found on the recorder's PTZ, channels 14 and 15).

### Changed
* The right-click item and the window "Detection log" are now called **Detection events**, because the window shows more
  than the log (events, pictures and tracks). The file is still `logs/Detection.log`.

## [3.3.0] - 11 Nov 2026

### Added
* **Check detection setup (read-only).** Right-click a camera, or use the *Check now* button in the sidebar, to see
  whether it is set up to report detection events: login, address, online, firmware, smart-event metadata, motion
  zone, line and area rules (drawn but switched off, or switched on with nothing drawn) and Notify Surveillance
  Center. Results open in a window and are also written to `logs/SetupCheck.log`. An optional tick box runs the check
  at start-up (off by default). It only reads, one request at a time, and stops at the first refused login so it cannot
  lock a camera out.
* **Setup check labels are no longer cut off.** Long labels wrap, and "lives in the camera / recorder" moved into the detail text.
* **The setup check says where a rule lives.** For a camera behind a recorder it now also reads the recorder's own
  line and area rules for that channel. If the recorder has a zone of its own it adds a note, "Intrusion rule lives in
  the camera and in the recorder" (or "in the recorder only"), with the zone numbers. This explains a mystery event
  whose saved picture shows a zone the camera does not have: the recorder can run its own rule and draws it on the
  picture. Found on Driveway (channel 16), where the recorder's intrusion zone is not in the camera.
* **Switch the detection frame on or off for all cameras in one list.** A new *Choose cameras...* button under the detection
  options opens a window with a tick box for every camera, grouped by recorder, with *All on* / *All off* for everything or
  for one recorder. It changes the same switches as the tile's right-click item, so the two always agree.
* **Event pictures are kept per camera, and how many is a setting.** The newest 100, 500 or 1000 pictures of each camera
  are kept (before, 100 in all, so one busy camera pushed out everyone else's). The choice is in the sidebar under the
  detection options; lowering it deletes the surplus at once.
* **Event pictures.** The picture a camera or recorder sends with a line or area event is kept (the newest 100, in
  `logs/pictures`; older ones are deleted). A recorder sends a link instead of the picture, and KVision downloads it
  with the recorder's login (one try; a refused login stops it). The detection log window has a new **Picture**
  column: a small button beside Play opens the picture, with the red target frame (and the rule line) when the
  camera's "Overlay Rule Frame and Target Frame on Background Picture" switch is on.
* **The setup check reports that switch.** It looks for the red outline on the rectangle an event names. The switch
  cannot be read or set over the camera's network interface, so the check only says where to find it.
* **Choose where cameras behind a recorder get their detection reports.** A new setting under User Interface Settings:
  *Each camera directly* (the default, one connection per camera) or *Through the recorder* (one connection to the
  recorder, which relays every camera's events with the channel number). A standalone camera, a dual-lens camera and a
  recorder with one or two cameras always use their own connection. Changing the setting takes effect at once.
* **Choose which reports show a frame.** Tick or untick Motion, Line crossing, Intrusion, Region entrance, Region exit
  and Other smart events, and the targets Human, Vehicle, Animal and Other. Untick Motion on a windy day and only smart
  events show. The detection log keeps every report whatever is unticked.
* On a recorder connection each report is written to the detection log under the right camera, using the channel
  number in the report, whether or not a tile shows that camera.

### Fixed
* **The frame label no longer follows plain motion right after a line or intrusion report.** For 10 seconds after a
  line, intrusion, entrance or exit report, a plain motion report (often somebody elsewhere in the picture) only
  keeps the frame alive and does not change its label. Before, a person at the desk could rename the frame of a dog
  in the intrusion zone to "HUMAN". The detection log still records every report.
* A motion report for another target no longer borrows the earlier kind name ("HUMAN - INTRUSION" when the camera
  said human motion).

* **Line crossings and intrusions from a camera's own connection were missed whenever the camera attached a picture.**
  The camera sends the picture just before the event. The code that looks for events stopped reading at the first zero
  byte in the picture, so the line or intrusion event after it was never seen, only plain motion before it. They now
  reach the detection log and the tile. Found on Livingroom-New, which sent dozens of line and intrusion events that
  KVision logged none of. Recorder connections were not affected, because a recorder sends links instead of pictures.
* **A stream that dies is reopened.** A camera that goes silent for 40 seconds (it normally sends a heartbeat every
  10) is reconnected, and a lost connection is retried with waits of 2, 4, 8, 16 and then 30 seconds for as long as a
  tile watches, where before three failures in a row stopped it for the rest of the session. A refused login still
  stops everything, so a wrong password cannot lock a camera. A device with no event stream (the Doorbell) is asked
  once.


### Changed
* The frame label, border and padding shrink with the tile's height, so the label no longer crowds a small or
  medium cell. The font is 12 px on tiles about 650 pixels high or more (it was 13 px on every tile), 10 px at about 430,
  and 8 px on small tiles. It never grows beyond 12 px.

### Documentation
* `docs/TODO.md` (the to-do list, with ideas from the Node-RED Hikvision project) and
  `docs/AUDIT-2026-11-10.md` (a record of the changes made on 10 Nov 2026 and how to undo them).

## [3.2.0] - 10 Nov 2026

### Added
* **On-screen event detection.** A tile shows a coloured frame and a caption when its camera reports a target: HUMAN, VEHICLE or ANIMAL, followed by the kind of report (`MOTION`, `LINE`, `INTRUSION`, `ENTER`, `EXIT`), for example `HUMAN - LINE`. It listens to each camera's event stream (`/ISAPI/Event/notification/alertStream`), one shared connection per camera. Off by default.
* **Smart events.** Line crossing, intrusion, region entrance and region exit reports show the frame as well as labelled motion reports. Plain motion with no target type never starts a frame, but keeps a showing one alive.
* **Cameras behind an NVR.** KVision looks up each camera's own address from the NVR and listens to it with the NVR's login. These start off and are switched on one at a time.
* **Per-camera switch.** Right-click a tile and choose "Detection frame" to turn it on or off for that camera. Switching it off closes that camera's connection at once.
* **Hold time setting** (3 to 30 s) for how long the frame stays after the last report. The settings are under User Interface Settings.
* **Detection log.** Every labelled report is written to `logs/Detection.log` in the configuration folder with the camera's own time, the target, the kind of report, the camera name and address, and the recorder and channel it plays back from. A report read 10 seconds or more late ends with `received HH:mm:ss`. `logs/Frames.log` records each frame a tile showed.
* **Detection log window.** Right-click a Hikvision tile and choose "Detection log..." for the newest 10 entries, a "Load 10 more" button, a Refresh button and an "Only this camera" filter. Double-click an entry, or press its play button, to open playback 10 seconds before the event. A moment with no recording simply shows no video.

### Changed
* The routine `libva info` lines are hidden unless KVision is started with `--verbose`. A `LIBVA_MESSAGING_LEVEL` you set yourself is left alone.

### Fixed
* The frame is hidden by comparing the clock with the last report, not with one long timer: a 30 s one-shot timer was seen to fire after about 19 s.
* A tile takes the camera's login from the saved recorder list. Using the tile's own password could send a blank one, which counts as a failed login and can lock a camera. The listener also stops for the session if a camera refuses its login.

### Documentation
* The README now says that on-screen detection depends heavily on correct detection settings inside each camera, and that setting them up takes attention to detail and patience.

## [3.1.0] - 9 Nov 2026

### Added
* **Hold-to-talk two-way audio** for Hikvision cameras. A microphone badge on live tiles sends your voice (G.711 u-law, 8 kHz) to the camera speaker while held. Cameras behind an NVR are reached directly using the address the NVR reports for them.
* Talk audio follows the format each camera requests: G.711 u-law, G.711 A-law, or AAC-LC with ADTS framing (needed by some older Hikvision doorbells). Unsupported formats are refused with a clear message.
* Voice processing for small camera speakers: high-pass filter, compression and a soft limiter so peaks never clip.
* Settings: talk microphone, microphone gain (0.5x-4x), output boost (-6 to +12 dB) and an on/off switch.
* Right-click the talk badge to read and set the camera's own speaker volume.

### Documentation
* README: logo at the top and a screenshots section (the pictures come from upstream 2.x and show the original interface).

## [3.0.0] - 9 Nov 2026

First release of this independent Linux-only fork. It starts from upstream KVision 2.7.5 (Arkanista) and is no longer tracking upstream. Earlier entries below are upstream history.

### Removed
* **Windows support:** the Windows build, CI workflow, `BUILD_WINDOWS.md`, icon resources and all `_WIN32` code paths. Hikvision's own client already covers Windows.
* **Packaging recipes:** `debian/`, `packaging/arch/` and `snap/`. Run with `./kvision`.
* **Other languages:** English is the only language and the language picker is gone.

### Live view and PTZ
* Mouse-driven PTZ pad, double-digit presets, focus near/far controls with tooltips, and the preset number clears after saving.
* Drag cameras between cells (including merged Panovision cells); cursor auto-hide in windowed mode and a startup size guard.
* Right-click menu: add or replace a camera from a recorder picker, and open the camera web UI.
* Per-tile fullscreen badge toggles window fullscreen in a 1x1 grid.
* Mouse-wheel zoom inside a box-zoomed viewport (live and playback); fixed zoom selection offset and panning for scaled video.
* Third Hikvision stream with the picture aspect ratio preserved.
* Channel resolution badge, info badges hide when idle, grids up to 18x18, always-on-top Add camera window, merged-cell resize fix.
* Mouse-wheel paging through saved layouts.

### Playback
* NVR smart events on the timeline with previous/next event controls, one-frame advance and 6x speed.
* Mark a range on the timeline and download it; quick playback gets seek, event markers and frame step.
* Snapshots can save the full image or the zoomed view. **File names now use the camera/NVR time of the frame shown** (decoder frame timestamp in playback, the recorder's clock in live view), not the PC clock.
* Standalone SD-card playback falls back to the SDK search; improved fullscreen playback.

### Recorder and camera management
* Generate Grid button on recorder cards, capped tile width in the recorder cameras window.
* Thumbnails wait for a keyframe and reject corrupt or flat frames.
* Per-recorder RTSP transport, custom HTTP/RTSP ports and local camera names.

### Build
* One-command install for Debian, Ubuntu and Linux Mint: `./install.sh` installs the packages, builds KVision and adds it to the applications menu. `./install.sh --update` and `--uninstall` are included.
* Builds on Debian 10 (GCC 9, Qt 5.11); root `./kvision` launcher configures, builds and starts the app.
* FFmpeg 4.4: the RTSP timeout option is no longer passed because it enables listen mode.

## [2.7.5] - 29 Oct 2026

### EN: Features, Improvements & Bug Fixes
* **Windows System Statistics Panel (`SystemStats` / `StatsWorker`):**
  * Implemented native Win32 CPU and RAM usage monitoring in `StatsWorker::calculateCpuAndRam()` using `GetSystemTimes()`, `GetProcessTimes()`, and `K32GetProcessMemoryInfo()` (`WorkingSetSize`), fixing `0.0%` CPU and `0.0 MB` RAM readings on Windows.
  * Added Windows multi-process discovery in `StatsWorker::getProgramPids()` via `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)` to aggregate CPU, RAM, GPU, VRAM, and Network metrics across all `kvision.exe` instances (`--auxiliary` multi-monitor windows) and child processes (`ffmpeg.exe`).
  * Added Windows GPU & VRAM monitoring via both NVIDIA `nvml.dll` (`C:\Windows\System32\nvml.dll`, including `_v2` symbol resolution and `NVML_VALUE_NOT_AVAILABLE` WDDM filtering) and universal Windows Performance Data Helper (`pdh.dll`) counters (`\GPU Engine(*)\Utilization Percentage` and `\GPU Process Memory(*)\Dedicated Usage` / `Local Usage`) supporting NVIDIA, AMD, and Intel GPUs.
  * Stabilized 1-second network speed (`Mbps`) and CPU delta sampling when opening the System Statistics panel by keeping background sampling aligned to the 1000ms timer and immediately publishing the latest cached sample via `StatsWorker::emitLatest()`.

### PL: Funkcje, Udoskonalenia i Poprawki Błędów
* **Panel statystyk systemu na Windowsie (`SystemStats` / `StatsWorker`):**
  * Dodano natywny pomiar zużycia procesora (CPU) oraz pamięci RAM w `StatsWorker::calculateCpuAndRam()` z użyciem funkcji Win32 API `GetSystemTimes()`, `GetProcessTimes()` oraz `K32GetProcessMemoryInfo()` (`WorkingSetSize`), eliminując problem stałego wyświetlania `0.0%` CPU i `0.0 MB` RAM na systemie Windows.
  * Dodano wykrywanie procesów na Windowsie w `StatsWorker::getProgramPids()` przy pomocy `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)`, dzięki czemu statystyki CPU, RAM, GPU, VRAM oraz sieci sumują wszystkie okna `kvision.exe` (tryb wielomonitorowy `--auxiliary`) i procesy potomne (`ffmpeg.exe`).
  * Dodano odczyt obciążenia GPU i pamięci VRAM na Windowsie poprzez bibliotekę NVIDIA `nvml.dll` (`C:\Windows\System32\nvml.dll` z obsługą symboli `_v2` i filtrowaniem wartości `NVML_VALUE_NOT_AVAILABLE` na sterownikach WDDM) oraz uniwersalne liczniki systemowe Windows PDH (`pdh.dll`: `\GPU Engine(*)\Utilization Percentage` i `\GPU Process Memory(*)\Dedicated Usage` / `Local Usage`) działające na kartach NVIDIA, AMD oraz Intel.
  * Ustabilizowano 1-sekundowy takt pomiaru prędkości sieci (`Mbps`) oraz delty CPU przy otwieraniu panelu statystyk (`StatsWorker::emitLatest()`).

## [2.7.4] - 29 Oct 2026

### EN: Features, Improvements & Bug Fixes
* **Archive Video Download & Conversion Pipeline (`HikvisionDownloader`):**
  * Bundled `ffmpeg.exe` in the Windows x64 release package (`KVision-windows-x64.zip`) and added `resolveFfmpegExecutable()` so `HikvisionDownloader` automatically finds `ffmpeg.exe` next to `kvision.exe` without flashing a console window (`CREATE_NO_WINDOW`).
  * Implemented a 3-tier `.pspart` -> `.mp4` conversion pipeline: (1) `ffmpeg` CLI with video stream copy and AAC audio transcoding (`-c:v copy -c:a aac`), (2) automatic retry without audio (`-c:v copy -an`) when Hikvision PS audio streams are corrupted or unsupported, and (3) a built-in in-process `libavformat` remuxer fallback (`remuxPsToMp4InProcess`) that converts `.pspart` directly to `.mp4` without requiring an external process.
  * Fixed Windows NTFS directory entry caching during active `HCNetSDK.dll` downloads by reading uncached file sizes via file handle (`getActualFileSize()`), and added stall detection (`m_stalledTicks`) to cleanly finish SDK downloads and trigger MP4 conversion as soon as the stream ends instead of hitting an SDK timeout (`pos == 200`) and deleting `.pspart`.
  * Preserved `.pspart` files on disk if all conversion tiers ever fail so downloaded footage is never lost.
* **Windows Snapshot & Recording Folder Browsing (`SnapshotSavedDialog`, `Context`):**
  * Fixed the **"Browse"** (`Przeglądaj`) button in `SnapshotSavedDialog.qml` after taking a quick viewport snapshot by adding the missing `import CCTV_Viewer.Core 1.0` import.
  * Added `Context::openLocalFolder()` with automatic directory resolution and a native `explorer.exe` fallback on Windows across `SnapshotSavedDialog.qml`, `DownloadDialog.qml`, `PlaybackWindow.qml`, and `SideBar.qml`.
* **Windows Executable Icon & Resource Metadata (`kvision.rc`, `images/kvision.ico`):**
  * Embedded a multi-resolution (`256x256` down to `16x16`) application icon and Windows PE `VERSIONINFO` resource into `kvision.exe`.

### PL: Funkcje, Udoskonalenia i Poprawki Błędów
* **Pobieranie i konwersja nagrań z archiwum (`HikvisionDownloader`):**
  * Dołączono `ffmpeg.exe` do paczki wydania Windows x64 (`KVision-windows-x64.zip`) oraz dodano automatyczne wykrywanie `ffmpeg.exe` obok `kvision.exe` (z ukryciem okna konsoli `CREATE_NO_WINDOW`).
  * Wdrożono 3-poziomowy mechanizm konwersji `.pspart` -> `.mp4`: (1) `ffmpeg` CLI z kopiowaniem wideo i transkodowaniem dźwięku do AAC (`-c:v copy -c:a aac`), (2) automatyczne ponowienie bez ścieżki audio (`-c:v copy -an`) w przypadku uszkodzonego strumienia dźwięku z rejestratora, oraz (3) wbudowany remukser `libavformat` działający bezpośrednio w procesie aplikacji (`remuxPsToMp4InProcess`).
  * Naprawiono odczyt rzeczywistego rozmiaru pliku `.pspart` na systemie plików NTFS podczas pobierania przez `HCNetSDK.dll` oraz dodano detekcję zakończenia strumienia (`m_stalledTicks`), która natychmiast zamyka sesję pobierania i uruchamia konwersję do `.mp4` zamiast czekać na błąd timeout SDK (`pos == 200`) i usuwać plik `.pspart`.
  * Zabezpieczono plik `.pspart` przed usunięciem w razie niepowodzenia wszystkich metod konwersji.
* **Przeglądanie folderu stopklatek i nagrań na Windowsie (`SnapshotSavedDialog`, `Context`):**
  * Naprawiono niedziałający przycisk **„Przeglądaj”** po wykonaniu szybkiej stopklatki w viewporcie (`SnapshotSavedDialog.qml`) poprzez dodanie brakującego importu `import CCTV_Viewer.Core 1.0`.
  * Dodano metodę `Context::openLocalFolder()` z natywnym wsparciem `explorer.exe` na systemie Windows we wszystkich oknach programu (`SnapshotSavedDialog.qml`, `DownloadDialog.qml`, `PlaybackWindow.qml`, `SideBar.qml`).
* **Ikona programu Windows (`.exe`) i metadane wersji (`kvision.rc`, `images/kvision.ico`):**
  * Osadzono wielorozdzielczą (`256x256` – `16x16`) ikonę programu KVision oraz zasoby `VERSIONINFO` bezpośrednio w pliku wykonywalnym `kvision.exe`.

## [2.7.3] - 28 Oct 2026

### EN: Features, Improvements & Bug Fixes
* **Windows x64 Build Support & CI Workflow:** Integrated full Windows x64 compilation support (`MSVC 2022` / CMake / GitHub Actions CI, contributed by @kunxiang1 in PR #7) with automated artifact packaging (`windeployqt`, FFmpeg, Hikvision SDK, OpenSSL, and cURL DLLs) and multi-mirror HTTPS fallback for `aqtinstall`.
* **Cross-Platform Settings Import / Export:** Added a new **"Import / Export"** tab in the side panel allowing one-click export and import of the entire application configuration (`.conf` / `.ini`) between Linux and Windows, with automatic adaptation of snapshot and video recording paths to the target operating system and live hot-reload.
* **Windows Configuration File (`KVision.ini`) & Path Fixes:** Enforced `QSettings::IniFormat` on Windows so settings are stored in a standard file (`%APPDATA%\KVision\KVision.ini`) instead of the Windows Registry, and replaced fixed `.substring(7)` URL stripping with `QUrl::toLocalFile()` / `QUrl::fromLocalFile()` so Windows paths no longer start with a leading slash (`/C:/...`).
* **Unified Dark `Compact` Theme & `CheckBox` Visual Overhaul:** Fixed `CheckBox` controls on Windows where Qt's default light system palette caused black label text and oversized (`24x24`) white indicator boxes. Redesigned `Compact/CheckBox.qml` (`18x18` dark indicator, `#00f5d4` celadon accent border and vector SVG checkmark, crisp `#ffffff` label text) and configured a complete dark `[Compact\Palette]` in `qtquickcontrols2.conf` for consistent styling across Windows and Linux.

### PL: Funkcje, Udoskonalenia i Poprawki Błędów
* **Obsługa wersji Windows x64 i CI:** Wdrożono pełne wsparcie kompilacji dla systemu Windows x64 (`MSVC 2022` / CMake / GitHub Actions CI, współtworzone przez @kunxiang1 w PR #7) wraz z automatycznym pakowaniem bibliotek DLL oraz obsługą zapasowych serwerów lustrzanych HTTPS dla `aqtinstall`.
* **Wieloplatformowy Import / Eksport ustawień:** Dodano nową zakładkę **„Import / Eksport”** w panelu bocznym umożliwiającą eksport i import pełnej konfiguracji programu (`.conf` / `.ini`) pomiędzy systemami Linux i Windows wraz z automatycznym dopasowaniem ścieżek zapisu stopklatek i wideo do docelowego systemu oraz przeładowaniem na żywo.
* **Naprawa pliku konfiguracyjnego (`KVision.ini`) i ścieżek na Windowsie:** Wymuszono format `QSettings::IniFormat` na Windowsie (zapis w pliku `%APPDATA%\KVision\KVision.ini` zamiast w Rejestrze Windows) oraz wyeliminowano błędny początkowy ukośnik (`/C:/...`) w ścieżkach katalogów stopklatek i nagrań wideo poprzez użycie `QUrl::toLocalFile()` i `QUrl::fromLocalFile()`.
* **Poprawki wizualne ciemnego motywu `Compact` i pól wyboru (`CheckBox`):** Naprawiono wygląd pól wyboru (`CheckBox`) w wersji dla Windowsa, gdzie domyślna jasna paleta systemowa Qt powodowała czarny, nieczytelny tekst etykiet oraz nienaturalnie duże (`24x24`) białe kwadraty. Przeprojektowano `Compact/CheckBox.qml` (kompaktowy ciemny wskaźnik `18x18`, seledynowe obramowanie i wektorowy znacznik SVG `#00f5d4`, biały tekst `#ffffff`) oraz zdefiniowano pełną ciemną paletę `[Compact\Palette]` w `qtquickcontrols2.conf`.

## [2.7.2] - 27 Oct 2026

### EN: Features, Improvements & Bug Fixes
* **Chinese (`zh_CN`) Localization Overhaul:** Rewrote all active Simplified Chinese UI strings with proper, consistent video surveillance industry terminology (e.g., `摄像机`, `录像机/NVR`, `码流`, `主码流/子码流`, `窗格`, `回放`, `云台`) and fixed typographic conventions and format placeholders (contributed by @kunxiang1 in PR #6).
* **Ubuntu/Debian Automated Installer & Troubleshooting:** Added `tools/install_ubuntu.sh` for one-step dependency installation and compilation on Ubuntu/Debian derivatives, along with a comprehensive 5-point RTSP & QtMultimedia troubleshooting guide across all 22 localized instruction manuals.
* **Hardware Decoder Software Fallback:** Fixed an issue in `QmlAVVideoDecoder::initVideoDecoder` where a failed `av_hwdevice_ctx_create` call (e.g., unavailable GPU/VAAPI/CUDA context) aborted decoder initialization and caused a black viewport; it now gracefully falls back to CPU software decoding.
* **Hikvision Auto/Sub Stream Mode Fix:** Fixed `player.isSubStream` binding in `ViewportsLayout.qml` so `hikvision://` channels properly switch to sub-streams (`02` / `streamType: 1`) in Auto (multi-camera grid) and forced Sub modes even when `secondaryUrl` is empty.
* **Diagnostic Log Option Localization (`LNG_00549`):** Replaced the hardcoded Polish string for the diagnostic logs checkbox in `SideBar.qml` with translation key `LNG_00549` across all 22 supported languages.
* **Critical QML Load Error Logging:** Updated `customMessageHandler` in `main.cpp` to allow hard QML component errors (`is not a type`, `Cannot assign`, `is not defined`, `non-existent property`, `Unable to assign`) through to `stderr` even when diagnostic logging is disabled.
* **Explicit `AVDictionaryPtr` Deleter Type:** Replaced the generic lambda parameter `[](auto p)` with explicit `[](AVDictionary **p)` in `QmlAVOptions` (`qmlavoptions.h`) for stricter C++17 compiler compatibility.

### PL: Funkcje, Udoskonalenia i Poprawki Błędów
* **Przebudowa chińskiego tłumaczenia (`zh_CN`):** Przepisano wszystkie aktywne komunikaty interfejsu w języku chińskim uproszczonym z użyciem spójnej, profesjonalnej terminologii branży telewizji przemysłowej (CCTV) oraz poprawiono konwencje typograficzne i znaczniki formatowania (współtworzone przez @kunxiang1 w PR #6).
* **Automatyczny instalator Ubuntu/Debian i rozwiązywanie problemów:** Dodano skrypt `tools/install_ubuntu.sh` do jednoetapowej instalacji zależności i kompilacji na systemach z rodziny Ubuntu/Debian oraz rozbudowano 5-punktowy poradnik diagnostyki strumieni RTSP i wtyczek QtMultimedia we wszystkich 22 wersjach językowych instrukcji.
* **Awaryjne przełączanie dekodera sprzętowego na CPU:** Naprawiono błąd w `QmlAVVideoDecoder::initVideoDecoder`, w którym nieudana inicjalizacja urządzenia sprzętowego (`av_hwdevice_ctx_create`, np. przy braku dostępnego kontekstu VAAPI/CUDA/GPU) przerywała otwieranie dekodera i powodowała czarny ekran — teraz następuje płynne przełączenie na dekodowanie programowe (CPU).
* **Poprawa trybu Auto/Sub dla strumieni Hikvision:** Naprawiono wiązanie `player.isSubStream` w `ViewportsLayout.qml`, dzięki czemu kanały `hikvision://` poprawnie przełączają się na strumień pomocniczy (`02` / `streamType: 1`) w trybie Automatycznym (w siatce wielokamerowej) oraz wymuszonym Sub, nawet gdy pole `secondaryUrl` jest puste.
* **Lokalizacja opcji logów diagnostycznych (`LNG_00549`):** Zastąpiono zahardkodowany polski napis przy opcji pełnych logów diagnostycznych w `SideBar.qml` kluczem tłumaczenia `LNG_00549` we wszystkich 22 obsługiwanych językach.
* **Logowanie krytycznych błędów ładowania QML:** Zaktualizowano filtr `customMessageHandler` w `main.cpp`, aby przepuszczał twarde błędy kompilacji/ładowania komponentów QML (`is not a type`, `Cannot assign`, `is not defined`, `non-existent property`, `Unable to assign`) na `stderr` nawet przy wyłączonych pełnych logach diagnostycznych.
* **Jawne typowanie deletera `AVDictionaryPtr`:** Zastąpiono generyczny parametr lambdy `[](auto p)` jawnym typem `[](AVDictionary **p)` w `qmlavoptions.h` dla pełnej zgodności ze standardem C++17.

## [2.7.1-rc5] - 27 Aug 2026

### EN: Features & Bug Fixes
* **Custom Ports Live Streaming Fix:** Fixed an issue where custom HTTP/RTSP ports failed to stream video in Live View. Added dynamic reactivity in `Player.qml` to NVR settings changes, robust IP matching, and proper credential URL encoding.
* **ISAPI Discovery Architecture:** Overhauled camera channel discovery to query IP Proxy channels (`InputProxy/channels`), Analog channels (`Video/inputs/channels`), and Streaming channels (`Streaming/channels`) independently, ensuring pure IP NVRs, hybrid DVRs, and standalone IP cameras discover channels reliably.
* **Universal Authentication Negotiation:** Switched ISAPI communication to `--anyauth` in curl to automatically negotiate between Digest and Basic authentication.
* **FFmpeg Demuxer Credential Encoding:** Ensured percent-encoded credentials in RTSP URLs are preserved cleanly when loaded by QmlAV demuxer.
* **Mock Hikvision NVR Test Server:** Added `tools/mock_hikvision_server.py` supporting both ISAPI HTTP discovery and RTSP H.264 video streaming on custom ports for local development and verification.

### PL: Funkcje i Poprawki Błędów
* **Naprawa odtwarzania na niestandardowych portach:** Rozwiązano problem z brakiem obrazu na żywo przy konfiguracji niestandardowych portów HTTP/RTSP. Dodano dynamiczne odświeżanie widoków w `Player.qml` po zmianie ustawień rejestratora, ulepszono dopasowywanie adresów IP oraz dodano bezpieczne kodowanie poświadczeń w URL.
* **Usprawnienie wykrywania kanałów ISAPI:** Zreorganizowano proces wykrywania kanałów, aby niezależnie odpytywać kanały IP (`InputProxy/channels`), analogowe (`Video/inputs/channels`) oraz uniwersalne strumienie (`Streaming/channels`), gwarantując pełną zgodność z rejestratorami IP NVR, hybrydowymi DVR oraz kamerami IPC.
* **Automatyczna negocjacja autoryzacji:** Zastosowano opcję `--anyauth` w curl, co pozwala na automatyczny wybór pomiędzy Digest i Basic Authentication.
* **Kodowanie poświadczeń w demuxerze FFmpeg:** Zabezpieczono przekazywanie zakodowanych znaków w adresach RTSP bezpośrednio do demuxera QmlAV.
* **Symulator rejestratora do testów:** Dodano skrypt `tools/mock_hikvision_server.py` symulujący rejestrator Hikvision (ISAPI + RTSP H.264) na dowolnych portach do testów lokalnych.

## [2.7.1-rc4] - 7 Aug 2026

### EN: Features & Bug Fixes
* **URI Migration:** Added an automatic migration script at startup to clean up old saved `hikvision://` URIs in existing layouts, ensuring legacy saved layouts also benefit from the simplified and secure URI format (removing credentials and ports from the UI).

### PL: Funkcje i Poprawki Błędów
* **Migracja adresów URI:** Dodano automatyczny skrypt migracyjny przy starcie programu czyszczący stare zapisane adresy `hikvision://` w istniejących układach, dzięki czemu wcześniejsze układy również korzystają z uproszczonego i bezpieczniejszego formatu URI (usunięcie haseł i portów z interfejsu).

## [2.7.1-rc3] - 7 Aug 2026

### EN: Features & Bug Fixes
* **Simplified Internal URIs:** Removed credentials and port numbers from internal `hikvision://` URIs, cleaning up the configuration and improving internal URL generation logic.
* **Custom Ports Handling:** Fixed a bug where HTTP ISAPI searches would incorrectly fallback to port 80 or the SDK port instead of the configured HTTP port.

### PL: Funkcje i Poprawki Błędów
* **Uproszczenie wewnętrznych URI:** Usunięto dane logowania i numery portów z wewnętrznych adresów `hikvision://`, upraszczając konfigurację i poprawiając logikę generowania URL.
* **Obsługa niestandardowych portów:** Naprawiono błąd, przez który wyszukiwanie nagrań ISAPI HTTP niepoprawnie powracało do portu 80 lub portu SDK zamiast skonfigurowanego portu HTTP.

## [2.7.1-rc2] - 7 Aug 2026

### EN: Features & Diagnostics
* **Diagnostic Logs:** Introduced a new UI option to enable writing comprehensive diagnostic logs (including previously silenced FFmpeg and QML errors) to a dedicated `kvision_diagnostic.log` file in the application config directory. This assists in troubleshooting issues like memory leaks or silent decoding failures.

### PL: Funkcje i Diagnostyka
* **Logi diagnostyczne:** Wprowadzono nową opcję w interfejsie umożliwiającą zapis pełnych logów diagnostycznych (w tym wyciszonych wcześniej błędów FFmpeg i QML) do dedykowanego pliku `kvision_diagnostic.log` w katalogu konfiguracyjnym aplikacji. Pomaga to w diagnozowaniu problemów z wyciekami pamięci lub cichymi błędami dekodowania.

## [2.7.1-rc1] - 4 Aug 2026

### EN: Features & Bug Fixes
* **Per-NVR RTSP Transport:** Added a dedicated RTSP Transport setting (Auto/TCP/UDP) for each NVR recorder. This resolves recent connection issues over WAN/NAT by allowing users to force a specific protocol for Live View per device.
* **RTSP Transport UI Sync:** Fixed a visual bug in the viewport settings dialog and sidebar where the displayed `-rtsp_transport` FFmpeg option did not reflect the specific NVR override. The UI now accurately reads and displays the dynamically injected transport protocol.

### PL: Funkcje i Poprawki Błędów
* **Protokół RTSP per Rejestrator:** Dodano możliwość ręcznego wyboru protokołu RTSP (Auto/TCP/UDP) indywidualnie dla każdego rejestratora NVR. Rozwiązuje to ostatnie problemy z połączeniami przez WAN/NAT, umożliwiając wymuszenie protokołu dla wybranego urządzenia.
* **Synchronizacja interfejsu RTSP:** Naprawiono błąd wizualny w oknie ustawień viewportu i na pasku bocznym. Wyświetlane tam parametry FFmpeg (`-rtsp_transport`) poprawnie odzwierciedlają teraz nadpisany protokół (UDP lub TCP) przypisany do konkretnego rejestratora NVR.

## [2.7.0] - 27 Jul 2026

### EN: Features & Improvements
* **Hikvision Multi-Port Support:** Implemented independent port configuration for SDK, HTTP, and RTSP ports per NVR recorder, enabling seamless connection to recorders using non-standard or custom forwarded ports.
* **Settings UI/UX Enhancements:** Replaced implicit placeholder labels with permanent text headers above all port input fields in the NVR settings panel, ensuring context remains clear when fields are populated.
* **Multi-Language Support & Localization:** Updated all 22 supported languages with accurate localization strings for new port options.

### PL: Funkcje i Udoskonalenia
* **Obsługa wielu portów Hikvision:** Wdrożono niezależną konfigurację portów SDK, HTTP oraz RTSP dla każdego rejestratora NVR, co umożliwia prawidłowe połączenie z urządzeniami używającymi niestandardowych portów.
* **Udoskonalenia interfejsu ustawień NVR:** Zastąpiono znikające etykiety stałymi nagłówkami tekstowymi nad polami wprowadzania portów, co gwarantuje pełną czytelność po wpisaniu wartości.
* **Lokalizacja i wsparcie wielojęzyczne:** Zaktualizowano wszystkie 22 wspierane języki o przetłumaczone frazy dla opcji portów.

## [2.6.3] - 8 Jul 2026

### EN: Bug Fixes
* **Console Memory Reporting:** Enhanced the periodic memory reclaiming timer to log the exact amount of RAM (in MB) successfully returned to the operating system kernel via `malloc_trim(0)`. This message is always visible in standard console output without requiring `--verbose` mode.

### PL: Poprawki Błędów
* **Logowanie odzysku pamięci:** Ulepszono mechanizm okresowego zwalniania pamięci, dodając precyzyjną informację o dokładnej ilości pamięci RAM (w MB) pomyślnie zwróconej do jądra systemu za pomocą `malloc_trim(0)`. Komunikat ten jest zawsze widoczny na konsoli, również w trybie normalnym bez konieczności uruchamiania z flagą `--verbose`.

## [2.6.2] - 8 Jul 2026

### EN: Bug Fixes
* **Reduced Log Spam:** Suppressed repetitive QML/JS warnings, TypeErrors, and video packet decoding errors (e.g. "Unable send packet to decoder: Invalid data found...") from default output. These diagnostic logs are now only visible when running with `--verbose`.
* **Periodic Memory Reclaiming:** Added a background timer that runs once every hour to perform garbage collection and call `malloc_trim(0)`, releasing any unused heap memory back to the Linux kernel.

### PL: Poprawki Błędów
* **Ograniczenie hałasu w logach:** Wyciszono uciążliwe i powtarzające się błędy silnika QML (np. TypeError) oraz błędy dekodowania pakietów wideo ze standardowego wyjścia. Te komunikaty diagnostyczne są teraz wypisywane tylko przy uruchomieniu z parametrem `--verbose`.
* **Okresowe zwalnianie pamięci:** Dodano działający w tle zegar, który raz na godzinę wymusza odśmiecanie pamięci oraz wywołuje `malloc_trim(0)`, zwracając wszelkie nieużywane zasoby pamięci podręcznej sterty z powrotem do jądra systemu Linux.

## [2.6.1] - 7 Jul 2026

### EN: Bug Fixes
* **Fixed GPU Driver Memory Leak (NVIDIA/GLX):** Resolved a critical memory leak within the graphics driver stack (primarily affecting NVIDIA) by ensuring that the previous GLX texture image binding is explicitly released via `glXReleaseTexImageEXT` before drawing the next frame onto the X11 pixmap.
* **Thread Count Optimization:** Restricted FFmpeg decoding to a single thread per stream by default (setting `thread_count = 1` instead of `0` / auto-detect), preventing CPU thread explosion (e.g., 24 threads per camera on AMD Ryzen 9 24-core CPUs) and drastically reducing overall RAM usage and system context switching overhead.

### PL: Poprawki Błędów
* **Eliminacja wycieku pamięci w dekoderze (NVIDIA/GLX):** Naprawiono krytyczny wyciek pamięci na poziomie sterownika graficznego (szczególnie NVIDIA), powodowany brakiem zwalniania powiązania tekstury GLX (`glXReleaseTexImageEXT`) przed aktualizacją pixmapy X11 nową klatką wideo.
* **Ograniczenie liczby wątków dekodowania:** Ustawiono domyślną liczbę wątków dekodera FFmpeg na `1` dla każdego strumienia (zamiast `0` czyli auto-wykrywania), zapobiegając eksplozji wątków (np. 24 wątki na kamerę na 24-rdzeniowych procesorach AMD Ryzen 9) i drastycznie zmniejszając zużycie pamięci RAM oraz narzut przełączania kontekstu.

## [2.6.0] - 3 Jul 2026

### EN: New Features
* **Localization Expansion:** KVision is now fully localized into 20 new AI-translated languages, bringing the total number of supported languages to 22 (English, Polish, and 20 new languages). Both the entire application interface (UI) and the complete user manuals have been translated.
  * **Supported Languages:** Arabic (ar), Bulgarian (bg), Czech (cs), Danish (da), German (de), Greek (el), Spanish (es), Finnish (fi), French (fr), Hungarian (hu), Italian (it), Dutch (nl), Norwegian (no), Portuguese (pt), Romanian (ro), Slovak (sk), Swedish (sv), Turkish (tr), Ukrainian (uk), and Chinese (zh_CN).
* **Viewport Quick Playback documentation:** Added comprehensive documentation explaining the circular arrow overlay button (Miniplayer) and its detailed features in all 22 user manuals.

### PL: Nowe Funkcje
* **Rozszerzenie Lokalizacji:** KVision został w pełni przetłumaczony na 20 nowych języków wspomaganych przez AI, co daje łącznie 22 obsługiwane języki (angielski, polski oraz 20 nowych). Przetłumaczono zarówno cały interfejs aplikacji (UI), jak i pełne pliki instrukcji użytkownika.
  * **Obsługiwane języki:** arabski (ar), bułgarski (bg), czeski (cs), duński (da), niemiecki (de), grecki (el), hiszpański (es), fiński (fi), francuski (fr), węgierski (hu), włoski (it), holenderski (nl), norweski (no), portugalski (pt), rumuński (ro), słowacki (sk), szwedzki (sv), turecki (tr), ukraiński (uk) oraz chiński uproszczony (zh_CN).
* **Dokumentacja szybkiego podglądu:** Dodano szczegółowy opis nowej ikony szybkiego podglądu wstecz (Mini-odtwarzacza) oraz jej działania we wszystkich 22 plikach instrukcji użytkownika.

---

## [2.5.0] - 3 Jul 2026

### EN: New Features
* **Pan Zoom:** Added the ability to freely pan the zoomed-in video (Live, Mini-player, Archive) by holding down the middle mouse button (scroll wheel) and dragging the cursor.
* **Proportional Zoom Selection:** Introduced the `Shift` shortcut. Holding down the `Shift` key while drawing a zoom rectangle forces the selection to lock into a 16:9 aspect ratio, strictly constrained to the viewport boundaries.
* **Enforced Window Positioning:** Completely replaced the legacy window geometry saving mechanisms due to unresolvable multi-monitor projection issues in Qt. The application (both the main window and auxiliary windows) now strictly enforces launching centered on the primary monitor at 90% of its resolution, ensuring stability and predictability across all setups.
* **Localization Refactoring:** Replaced all hardcoded Polish and English strings embedded in the source code (`qsTr`, `tr`). Over 500 unique strings have been refactored into `LNG_XXXXX` identifiers, securely mapped via an improved `.ts`/`.qm` file system.
* **English-only CLI:** Command-line interface options and `--help` parameters are now permanently in English to prevent issues with delayed localization engine initialization.

### EN: Bug Fixes
* **Archive Aspect Ratio:** Fixed an issue where the aspect ratio of the video was distorted in the Archive player viewport. The `HikvisionArchivePlayer` component now correctly renders the original frame preserving its natural aspect ratio (letterboxing), instead of stretching the video to fit the UI boundaries.
* **Demuxer Memory Leaks:** Improved the object cleanup logic in the `QmlAVPlayer::stop()` routine, preventing "zombie" demuxer instances from accumulating in the background.
* **writeSetting Fix:** Added the missing implementation of the `writeSetting` method in the `Context` class, eliminating `TypeError`s and QML execution interruptions during settings migrations.

---

### PL: Nowe Funkcje
* **Przesuwanie powiększenia (Pan Zoom):** Dodano możliwość swobodnego przesuwania przybliżonego obrazu (Live, Mini-odtwarzacz, Archiwum) poprzez przytrzymanie wciśniętego środkowego przycisku myszy (kółka) i przesuwanie kursorem.
* **Proporcjonalne zaznaczanie powiększenia:** Wprowadzono skrót klawiszowy `Shift`. Trzymając wciśnięty klawisz `Shift` podczas rysowania prostokąta powiększenia (Lupka), zaznaczenie wymusza zablokowanie proporcji ekranu do 16:9, ograniczając ramkę do granic viewportu.
* **Wymuszone pozycjonowanie okien:** Zrezygnowano całkowicie z zapisywania geometrii okien po napotkaniu nieodwracalnych problemów Qt z poprawnym rzutowaniem na ekrany wielomonitorowe. Zamiast tego, aplikacja (zarówno okno główne, jak i okna pomocnicze) wymusza teraz otwieranie wyśrodkowane na głównym monitorze, w proporcjach 90% jego rozdzielczości, zapewniając stabilność i przewidywalność działania na każdym stanowisku.
* **Refaktoryzacja systemu tłumaczeń (Lokalizacja):** Zlikwidowano wszystkie sztywne polskie i angielskie teksty osadzone w kodzie źródłowym (`qsTr`, `tr`). Ponad 500 unikalnych ciągów zastąpiono jednolitymi identyfikatorami w formacie `LNG_XXXXX`, które są bezpiecznie mapowane przez ulepszony system plików `.ts`/`.qm`.
* **Wymuszony angielski w wierszu poleceń (CLI):** Opcje i parametry `--help` zostały zangielszczone na stałe, by uniknąć problemów z opóźnioną inicjalizacją mechanizmów lokalizacyjnych.

### PL: Poprawki
* **Zachowanie proporcji obrazu w Archiwum:** Naprawiono błąd zniekształcania proporcji obrazu w viewporcie odtwarzacza Archiwum. Komponent `HikvisionArchivePlayer` renderuje teraz oryginalną klatkę zachowując jej naturalny aspekt (dodając czarne paski), zamiast rozciągać wideo do wielkości okienka w interfejsie.
* **Wycieki pamięci Demuxerów:** Poprawiono logikę oczyszczania obiektów (cleanup) w procesie `QmlAVPlayer::stop()`, co zapobiega tworzeniu się "zombie" instancji demuxerów w tle.
* **Naprawa błędu writeSetting:** Dodano brakującą implementację metody `writeSetting` w klasie `Context`, co eliminuje błędy `TypeError` i przerywanie wykonywania kodu w QML przy migracjach ustawień.
