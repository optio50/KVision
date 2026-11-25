# User Manual for KVision

**KVision** is a Linux desktop viewer for Hikvision cameras and NVR/DVR recorders. It shows many live video streams (RTSP/ONVIF) at once, plays back recordings from the recorder, and listens to the cameras' detection reports (people, vehicles, line crossing, intrusion and more) to draw a frame on the tile and keep a log with pictures.

**Support KVision:** if you find it useful, you can support its development by [donating with PayPal](https://paypal.me/optio50).

This manual describes KVision 3.9. The Changelog tab in the options window lists what changed in each release.

---

## Table of Contents
1. [Description of Button Actions](#1-description-of-button-actions)
2. [Installation and Launching](#2-installation-and-launching)
3. [Managing NVR/DVR Recorders](#3-managing-nvrdvr-recorders)
4. [Live View and Viewport Overlays](#4-live-view-and-viewport-overlays)
5. [Screen Layouts, Presets, and Toolbar](#5-screen-layouts-presets-and-toolbar)
6. [System Statistics Panel (System Stats)](#6-system-statistics-panel-system-stats)
7. [Playback Archive Player](#7-playback-archive-player)
8. [Downloading Recordings (Downloader)](#8-downloading-recordings-downloader)
9. [Advanced Settings and Customization in Options Window](#9-advanced-settings-and-customization-in-options-window)
10. [Keyboard Shortcuts and Mouse Controls](#10-keyboard-shortcuts-and-mouse-controls)
11. [Taking Snapshots and Path Configuration](#11-taking-snapshots-and-path-configuration)
12. [The Right-Click Menu and Quick Tools](#12-the-right-click-menu-and-quick-tools)
13. [Detection Events: Frames, Log and Pictures](#13-detection-events-frames-log-and-pictures)
14. [Camera Tools (Backup, Clock, Firmware, Reboot)](#14-camera-tools-backup-clock-firmware-reboot)

---

## 1. Description of Button Actions

This section describes the meaning of all graphical icons and buttons used in the application.

### Top Tool Bar
* {ICON:quit} **Close Window**: Prompts for confirmation and closes the active window or application.
* {ICON:pin} **Pin Bar**: Locks the top bar in an expanded state or enables auto-collapsing.
* {ICON:fullscreen} **Full Screen**: Toggles the active window into fullscreen mode.
* {ICON:minimize} **Minimize**: Minimizes the application window to the system taskbar.
* {ICON:options} **Options**: Opens or closes the configuration options window (settings and recorders).
* {ICON:new_window} **New Window**: Opens a new, independent auxiliary window for camera streams.
* {ICON:archive} **Archive**: Opens the playback recordings archive window (timeline and calendar).
* {ICON:instructions} **Instructions**: Opens this user manual and technical assistance window.
* {ICON:stats} **Stats**: Toggles the sliding system statistics panel (CPU, RAM, GPU, Net).
* **Recorder status**: Green when the last recorder check was clean, red when a recorder reported a problem. Opens the NVR Status window. Shown while recorder monitoring is on and at least one recorder is saved.
* {ICON:lock} **Grid Lock**: Disables grid division adjustments to protect your active layout.
* {ICON:hamburger} **More Options**: Opens the sliding toolbox for advanced division sizes, ratios, and cell merging.

### Viewport Overlays (Cameras)
* {ICON:snapshot} **Snapshot**: Captures a lossless full-resolution image and saves it as a JPEG file.
* {ICON:play} **Camera Archive**: Launches the timeline playback window for this camera (15 minutes backward).
* {ICON:quick_play} **Quick Playback (Miniplayer)**: Initiates an in-viewport archive playback of the last 30 minutes, allowing you to quickly review recent footage directly in the camera tile without leaving Live view.
* {ICON:grid_1x1} **Try 1:1**: Displays the video stream in its original, native resolution without stretching.
* {ICON:zoom_in} **Interactive Zoom**: Toggles click-and-drag magnification for a selected marquee region.
* {ICON:zoom_out} **Reset Zoom**: Resets the digital magnification and restores the full camera field of view.
* {ICON:speaker_unmute} **Mute Audio**: Represents an unmuted audio stream; clicking it mutes the stream.
* {ICON:speaker_mute} **Unmute Audio**: Represents a muted audio stream; clicking it unmutes the stream.

### Playback Window Controls

**Top Bar Controls:**
* {ICON:close} **Close**: Closes the playback archive player window.
* {ICON:pin} **Pin Bar**: Locks the top bar in an expanded state or enables auto-collapsing.
* {ICON:fullscreen} **Full Screen**: Toggles the playback window into fullscreen mode.
* {ICON:sidebar} **Show/Hide Sidebar**: Toggles the visibility of the left sidebar containing cameras and recorders.
* {ICON:timeline_show} / {ICON:timeline_hide} **Show/Hide Timeline**: Shows or hides the bottom panel containing the timeline and playback controls.
* {ICON:video_folder} **Video Folder**: Opens the local system folder containing downloaded video clips.
* {ICON:photo_folder} **Snapshot Folder**: Opens the local system folder containing captured snapshots.
* grid buttons `1x1`, `1x2`, `2x1`, `2x2`: Switches the camera display layout of the playback window to 1, 2 (vertical/horizontal) or 4 concurrent views.

**Bottom Bar & Timeline Controls:**
* {ICON:prev_day} **Previous Day**: Navigates to recordings of the previous calendar day.
* {ICON:calendar_select} **Date Picker**: Opens a calendar dialog to select a specific date for playback.
* **Smart**: Click a recorder in the list on the left to search every camera on it, or click one camera to search only that camera, then Smart. The line at the top of the window says every camera on the recorder, or that camera's name. Tick Human, Vehicle, Face or Other under Target Type, and Line crossing, Intrusion or Region entrance under Event Type. Nothing is ticked until you tick it. An event tick keeps only that event. With no event ticked, every event for the chosen target is listed. Human lists up to the newest 200 Detection-event pictures, plus up to 100 from the recorder. Vehicle and Other each list up to the newest 400. The text under each picture shows the camera, the target, the event, and the time. Clicking a result starts five seconds before that moment. A camera that only keeps event recordings on its card, and not smart-search pictures, lists those recordings instead. Click one and playback starts at that time. The note also says KVision's Detection events may have the properly tagged event for the video timestamp. Playback sound starts at one tenth of full volume.
* {ICON:next_day} **Next Day**: Navigates to recordings of the next calendar day.
* {ICON:today} **Today**: Instantly shifts the playback focus to the current calendar day.
* {ICON:refresh_recordings} **Refresh recordings**: Refreshes and re-queries available recording segments from the device.
* {ICON:zoom_1h} / {ICON:zoom_8h} / {ICON:zoom_24h} **Timeline Zoom Presets**: Scales the visible window of the timeline (to 1 hour, 8 hours, or 24 hours) for high-precision navigation.
* {ICON:timeline_center} **Center Timeline**: Centers the timeline view precisely around the current playback timestamp.
* {ICON:speed_1x} / {ICON:speed_2x} / {ICON:speed_4x} **Playback Speed**: Adjusts the video playback multiplier (standard 1x speed, 2x accelerated, or 4x rapid play).
* {ICON:download} **Download**: Opens the download tool to export a defined video segment from the device.
* {ICON:jump_back_60} / {ICON:jump_back_45} / {ICON:jump_back_15} **Jump Backward**: Rewinds the playback timestamp by 60, 45, or 15 seconds.
* {ICON:play} / {ICON:pause} **Play / Pause**: Initiates or pauses the archive video stream playback.
* {ICON:jump_forward_15} / {ICON:jump_forward_45} / {ICON:jump_forward_60} **Jump Forward**: Advances the playback timestamp by 15, 45, or 60 seconds.

**Other Diagnostic & General Icons:**
* {ICON:calendar} **Calendar**: Represents calendar/scheduling configurations.
* {ICON:clock} **Time**: Represents clock or temporal status indicators.
* {ICON:zoom} **Zoom**: Represents scaling or digital zoom configurations.
* {ICON:timeline_toggle} **Timeline Toggle**: Represents toggling or refreshing of chronological views.
* {ICON:trash} **Delete**: Safely removes configured recorders or layouts with confirmation.
* {ICON:warning} **Warning**: Displayed in dialog boxes for irreversible actions or delete warnings.

---

## 2. Installation and Launching

### Manual Compilation (from source code)
If you want to compile the program manually (for example on another Linux distribution):

1. Install the required build and runtime dependencies using your package manager. For Arch Linux / CachyOS:
   ```bash
   sudo pacman -S base-devel cmake qt5-declarative qt5-multimedia qt5-quickcontrols qt5-quickcontrols2 qt5-svg qt5-graphicaleffects qt5-tools ffmpeg git qt5-wayland
   ```
2. Configure the project using CMake:
   ```bash
   cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
   ```
3. Compile the code:
   ```bash
   cmake --build build -j$(nproc)
   ```
4. Install the application in the system:
   ```bash
   sudo cmake --install build
   ```

### Installing on Ubuntu / Debian / Linux Mint

The installer does everything: it installs the required packages, builds KVision and adds it to your applications menu.

```bash
git clone https://github.com/optio50/KVision.git
cd KVision
./install.sh
```

It asks for your password once, to install packages. The first build takes a few minutes. When it prints "Done", open **KVision** from your applications menu.

* **Update:** `./install.sh --update`
* **Remove:** `./install.sh --uninstall` (your settings in `~/.config/KVision` are kept)
* Keep the KVision folder where it is, because the menu entry points to it.
* Do not run KVision or the installer as root.

### Launching

From the repository directory:

```bash
./kvision
```

A system-wide install is optional:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
sudo cmake --install build
kvision
```

### 🔧 Troubleshooting: Video Streams & Ubuntu Setup

#### Cameras are discovered, but Live View shows a black screen or exclamation mark
If KVision connects to your NVR, retrieves the camera names, but the video feeds fail to play:

1. **Missing QtMultimedia runtime plugins (Ubuntu/Debian):**
   Make sure runtime multimedia plugins are installed (these are separate from development headers):
   ```bash
   sudo apt update
   sudo apt install -y libqt5multimedia5-plugins qml-module-qtmultimedia
   ```
   Without `libqt5multimedia5-plugins`, Qt Quick's `VideoOutput` engine cannot render decoded video frames onto the screen.

2. **RTSP Transport Protocol (UDP vs TCP):**
   By default, RTSP stream negotiation may attempt UDP. Most network firewalls, routers with port forwarding (NAT), and many Hikvision units drop UDP packets.
   * In KVision, open **NVR Settings** (gear icon) and edit your recorder.
   * Set **RTSP Transport** to **`TCP`** (instead of Auto or UDP).

3. **Run from the repository or install it:**
   `./kvision` from the repository directory is the normal way to run this copy. A system install with `sudo cmake --install build` is optional.

4. **Verify RTSP stream outside KVision:**
   You can verify whether your camera's RTSP feed is reachable on your system by running:
   ```bash
   ffplay -rtsp_transport tcp "rtsp://USER:PASSWORD@IP:PORT/Streaming/Channels/101"
   ```
   If `ffplay` streams video properly with `-rtsp_transport tcp`, but KVision displays a black screen, verify that `libqt5multimedia5-plugins` is installed.

5. **Isolate Network/Router vs Local Issues using the Mock NVR Server:**
   You can run a local simulated Hikvision NVR to test streaming and custom ports in a completely isolated environment (no external network, router, or physical NVR needed):
   ```bash
   python3 tools/mock_hikvision_server.py --http-port 17080 --rtsp-port 17554
   ```
   Then in KVision, add a new NVR with:
   * **IP:** `127.0.0.1`
   * **HTTP Port:** `17080`
   * **RTSP Port:** `17554`
   * **Username:** `admin`
   * **Password:** `12345`
   * **RTSP Transport:** `TCP`
   
   Click **"Discover Cameras"** and add. If video plays with the mock server, KVision and custom port handling are functioning properly on your system, and any streaming failure with your real NVR is due to network/NAT/firewall routing or physical device configuration.

### Troubleshooting System Scaling (KDE Plasma)

KVision automatically detects and correctly applies fractional desktop scaling (e.g., 125%, 145%, 150%) configured in KDE Plasma settings by enforcing native High DPI pass-through policies in Qt. The user interface should scale correctly out-of-the-box without any manual intervention.

#### Native Wayland Support

To ensure the best scaling experience and performance under Wayland, make sure you have the optional `qt5-wayland` package installed on your system. This allows KVision to run natively on Wayland instead of falling back to XWayland.

For Arch Linux / Manjaro / CachyOS:
```bash
sudo pacman -S qt5-wayland
```

For Debian / Ubuntu / Linux Mint:
```bash
sudo apt install qtwayland5
```

#### Manual Scaling Override (Legacy/Fallback)

If you are running an unusual configuration, or simply wish to manually force a different scaling factor than the rest of the system, you can still override the application scaling using environment variables.

For example, to force **150%** scaling, launch the application from the terminal with:
```bash
env QT_FONT_DPI=96 QT_SCALE_FACTOR=1.5 kvision
```

*(You can permanently apply this by editing the application launcher `kvision.desktop` in the KDE menu editor and adding these variables to the "Environment variables" field).*

---

## 3. Managing NVR/DVR Recorders

To configure the connection to a Hikvision recorder:
1. Open the options window and go to the **Recorders** tab (server icon).
2. **Optional: find the device.** Click **Scan network**. KVision asks every network this computer is connected to for Hikvision devices (about 4 seconds) and lists what answers, with the model, address, serial number and which of your networks heard it. Click a row to fill in the name, IP address and ports, then type the user name and password. A row can carry notes: *Already added*, *Not activated: set a password on the device first*, and *Different subnet from this computer* (the device cannot be reached until its address is changed or a route exists). On a small network the same inquiry is also sent to each address, so a recorder that ignores the multicast still shows up. If nothing is found, the device may be on another subnet or VLAN, or it may have discovery turned off; enter its address by hand. A camera that sits behind a recorder you have already added is not listed, because that recorder already gives you the camera. The scan only listens for answers and sends no password.
3. Enter the device access details:
   * **IP Address**: The network address of the recorder.
   * **Port**: The SDK network port (default is `8000`).
   * **Username**: User name (e.g., `admin`).
   * **Password**: Password to access the recorder.
   * **Recorder Password.** To the right of **Scan network** and **Add Stream** there is a **Recorder Password** box, and beside its label a **Use Recorder Password** tick (on by default). With the tick on and a password typed, each recorder you add logs in with that password, and the Password field on the form says *Using recorder password*. The box is cleared when KVision closes and is not written to the settings. Each added recorder still keeps its own password, and that saved password is what KVision uses the next time it opens. Leave the box empty, or untick it, to type a password on the form for that one device.
4. Click **Connect & Discover** (or **Save & Update**).
   **Add Stream.** Next to Scan network, **Add Stream** saves a camera that is only an `rtsp://`, `http://` or `https://` address. Type a name, paste the address, and an optional description, then Save. HTTP Live Streaming (HLS) `.m3u8` playlists are accepted and play through the existing FFmpeg player. The stream is stored with the recorders as a one-channel camera, so it stays after a restart and after Import / Export, and it shows in **Add camera** and **Replace camera**. A password in the address that contains `@`, `#` or `%` is kept. Edit and delete are the pencil and the trash can on its card. KVision does not log in to it and does not contact it at startup, so an address that is down does not stop the program from opening. PTZ, detection, playback and smart search stay on Hikvision cameras.
5. Upon successful connection, the application will automatically detect all active cameras (channels) connected to the NVR/DVR and add them to the list.
5. **Generate Grid**: On each recorder card, click the four-squares icon (tooltip *Generate Grid*). It creates a new, separate layout containing every camera of that recorder in the smallest square-ish grid that fits them (for example 17 cameras give a 5x4 grid), names it after the recorder, and switches to it. It can be used any number of times, and each click makes another layout, so delete extras in the **Presets** tab. A layout is also created automatically the first time you add a recorder.
6. **Displaying Camera Lists (NvrCamerasWindow)**: Clicking the computer monitor icon button on any recorder's card opens a dedicated window showing all detected camera channels as interactive tiles.
7. **Generating Thumbnails (Generate thumbnails)**: In the NVR cameras list window, a *„Generate thumbnails”* button is available. Clicking it commands the application to pull single frames from each channel's Sub Stream in the background, setting them as the tile background thumbnails. This provides a quick visual preview of each camera without launching full live feeds.
8. **Adding a Camera**: Right-click an empty viewport and choose **Add camera**. A picker lists the configured recorders. A standalone camera is a recorder with one channel, so clicking that row assigns it immediately. A saved stream is one of those rows, and choosing it puts that address on the tile. A multi-channel recorder has an arrow; expand it and click one channel to place that camera in the cell you right-clicked. Right-clicking a viewport that already has a camera offers **Replace camera**, which uses the same picker. The green **"+" (Assign to active viewport)** button in the NVR camera list still works as a secondary path: left-click a viewport to focus it, then click **+** on a camera tile. Dragging tiles from the camera list onto the grid is not supported.
9. **SDK Session Status (Dot indicator)**: Beside each recorder's IP on the list, there is a colored status dot:
   * **Green (LOGGED IN)**: Represents an active Hikvision SDK session, which is required for PTZ control, timeline archive requests, and downloading.
   * **Red (NOT LOGGED IN)**: No active SDK session is currently established (e.g. before the first SDK request or after manual/automatic logout). Note that camera RTSP live feeds will continue to play independently of the SDK session status.
10. **Local Camera Renaming**: On any camera tile in the NVR cameras list, click the **Edit** (pencil) icon. This opens a dialog allowing you to set a custom name for the camera. This name is saved locally and instantly updates across the live players, timeline, and tile views without modifying the physical NVR device. You can reset it to the default name at any time.
11. **Removing a Recorder from List**: Beside each configured recorder on the list, there is a red trash can button. Clicking it initiates a two-stage security protocol designed to prevent accidental deletion:
    * **Step 1 (Confirmation)**: A dialog titled *“Confirm NVR Deletion”* appears, asking if you are sure you want to delete the recorder.
    * **Step 2 (Warning)**: A second warning dialog titled *“Warning!”* appears, asking if you are absolutely sure and aware of what you are doing.
    * **Effect of Deletion**: Upon accepting the second warning, the program logs out from that NVR in the background and deletes its entry from the application configuration. Saved layouts stay, including tiles that used this recorder.

---

### 3D badge (PTZ cameras)

A PTZ camera with a close-up lens and a fixed wide lens can be pointed by drawing on the wide view:
1. On a PTZ tile, find the small **3D** badge with the other badges at the bottom right. It appears on the wide lens and on the close-up lens of a two-lens PTZ, and on a single-lens PTZ, after the pointer has been over the tile for a moment. Fixed cameras do not have it.
2. Press **3D**, either the badge at the bottom right or the **3D** button on the PTZ pad (the empty slot between Zoom out and Zoom in). It stays lit, like the zoom button, and a note at the top of the tile says it is on. Both buttons work the same and light together.
3. Drag a box on the picture. On the wide lens the close-up lens turns to that spot; on the close-up lens (or a single-lens PTZ) the lens re-centers on the box. Either way the camera zooms in: the smaller the box, the closer the zoom. Draw as many boxes as you like.
4. Press **3D** again to turn it off.

It also turns off if the tile is zoomed in or put at 1:1. The tile shows what happened at the top. The badge is dimmed while the tile is zoomed in or at 1:1; reset the zoom first. It does not need the PTZ pad. Nothing is saved on the camera.

---

### Camera status

**Settings > Camera Tools > Camera settings (read only)...** (or right-click a camera > Quick tools > Camera settings) has a **Status** section for each camera: how long it has been up, how busy its processor and memory are, how often it has restarted, how long it has run in total, how much its moving parts have worked (a PTZ's zoom, focus, iris, pan and tilt, and the day/night filter), and whether its fan or heater is on. Values are green when fine, grey for a note, orange for a warning and red for a problem. The **All cameras** table has **Up**, **CPU** and **Memory** columns with the same colors, so you can compare cameras at a glance. **Right-click a camera > Quick tools > Camera settings** opens the same window already on that camera and reads it at once, so the Status section is one of its sections.

A restart in the last hour is a warning and a restart in the last day a note. A processor at 95% or more is a warning, and so is memory at 97% or more or under 12 MB free (most cameras sit at 80 to 95%, so a lower limit would flag nearly all of them). Most fixed cameras do not keep a restart count or running time and the row says so. The running time is in minutes. The processor figure changes from second to second, so one reading is not a trend. The camera's status is read first, before the other settings, so it shows the camera at rest. It only reads; nothing on a camera is changed.

---

## 4. Live View and Viewport Overlays

The main window of the program displays the live feed:
* **Camera Grid**: Displays RTSP streams or feeds directly from the Hikvision SDK.
* **Stream Quality Selection**: By right-clicking a camera viewport, you can select the **Main Stream** for highest resolution, or the **Sub Stream** to reduce network and graphics card load.
* **Double-Click Fullscreen Toggle**: Double-clicking with the left mouse button on any camera viewport instantly maximizes it to fill the entire active window area (single-viewport fullscreen). Double-clicking again restores the original multi-camera grid layout.
* **Auto-hiding Top Bar**: The top options toolbar (topToolBar) can automatically collapse to the top edge of the screen when the mouse cursor leaves its area (this option is configurable in Settings -> *„Automatically collapse top bar”* or directly using the pin icon on the top bar).
* **Multi-Monitor & Auxiliary Windows**: You can open independent additional (auxiliary) windows to run different grid layouts simultaneously on multiple screens or monitors. To open a new window, use the `Ctrl+N` keyboard shortcut, or click the **"New Window"** button on the hover-slide top toolbar. Each window can be configured with its own grid size and selected preset layout. Settings > User Interface Settings > **Auxiliary window size** chooses the scale of the next auxiliary window: same as the main window, Normal (1) for a 1080p or 720p screen, Medium (1.5) for 1440p, or Large (2) for a 4K screen. Normal is the default.

### Viewport Overlay Buttons
In the bottom-right corner of each camera tile/viewport, a control panel with five functional icons is displayed when hovering the mouse cursor over it (depending on UI preferences). A camera that supports them also shows a **microphone** button (hold it to talk through the camera's speaker; right-click it for the speaker volume, which is saved on the camera) and a **PTZ** button that opens the pan/tilt/zoom pad with presets:
1. **Camera Icon (Snapshot)**: Allows you to take a screenshot from the camera feed. The snapshot is saved in the full, native resolution of the stream directly from the decoder frame buffer, avoiding any losses due to the current size of the viewport tile or screen resolution scaling. Successful snapshot saving is confirmed by the camera icon flashing orange (`#ff7a00`) for exactly 1 second.
2. **Play Icon (Archive)**: Used to quickly open the recordings archive. Clicking this button automatically launches the timeline `PlaybackWindow` for this specific camera, starting the playback **exactly 15 minutes before the current system time** (a convenient quick backward offset).
3. **Circular Arrow Icon (Quick Playback / Miniplayer)**: Activates a quick in-viewport playback of camera archive recordings from the last 30 minutes directly inside the camera tile without leaving the live grid or launching the full archive window.
   * **Control Panel**: When active, a sliding control panel appears at the bottom of the viewport containing:
     * **Play/Pause**: Pauses or resumes the playback stream.
     * **Time & Offset Display**: Displays the current playback timestamp and its relative age compared to real time (e.g., `-12:34` represents 12 minutes and 34 seconds ago).
     * **Interactive Timeline Slider**: Allows clicking or dragging to seek anywhere within the 30-minute buffer. Available recording segments are highlighted with a teal background, and a red playhead marks the current position.
     * **Speed Multiplier**: Cycles through playback speeds (`1x`, `2x`, and `4x`) to scan footage rapidly.
     * **Close (✕)**: Closes the miniplayer and instantly returns the viewport to the live feed.
   * **Pannable Zoom support**: Just like in Live view, you can use the magnifying glass tool to zoom in on a region of the miniplayer, or hold the middle mouse button and drag to pan around.
4. **1:1 Icon (Native Scale)**: Toggles pixel-to-pixel video display mode. When enabled, the video is not stretched or distorted to fill the tile boundaries, but is instead centered and shown in its original native resolution. When this mode is active, the button background and "1:1" text are highlighted in bright neon light-turquoise.
5. **Magnifying Glass Icon (Interactive Zoom)**: Allows you to magnify any specific region of the video feed:
   * **Activation**: Clicking the icon toggles it into an active state (turquoise highlight). The cursor changes shape, and a tooltip instructs: *“Click and drag on camera feed to zoom”*.
   * **Operation**: Left-click and drag a rectangular marquee region over the live feed. The viewport will automatically crop and scale the selected area to fill the entire tile.
     * **Proportional Zoom**: Hold down the **Shift** key while drawing the zoom rectangle to force the selection to lock into a 16:9 aspect ratio, strictly constrained to the viewport boundaries.
     * **Panning the Zoomed Image (Pan Zoom)**: Once zoomed in, you can hold down the **middle mouse button (scroll wheel)** and drag the cursor to freely pan the magnified view around the video field of view. This works in Live view, the Playback Archive, and the Mini-player.
   * **Reset**: When zoomed, the magnifying glass icon changes its icon (red border with a minus sign). Clicking it immediately resets the zoom, returning to the full camera feed.

---

## 5. Screen Layouts, Presets, and Toolbar

Layouts allow you to organize the arrangement of cameras on the screen. From the **Presets** tab (star icon) you can:
* **Create New Presets**: Add your own layout with any configuration of columns and rows (e.g., 2x2, 3x3, 4x4).
* **Assign Cameras**: Right-click an empty viewport and choose **Add camera**, then pick a recorder or expand it and pick a channel. On a filled viewport, **Replace camera** does the same. You can also focus a viewport and use the green **"+" (Add)** button in the NVR cameras window. Viewport positions can be swapped from the right-click menu (**Swap viewports**) of the source viewport, then clicking the target viewport.

### Top Bar Buttons (Top Tool Bar)
The top sliding toolbar provides a comprehensive set of navigation and application control buttons:
1. **Close Window (Red ✕ Button)**: Closes the active window. To prevent accidental clicks, it intercepts the closing event and prompts you with a dialog box to confirm exiting the application.
2. **Pin Button**: Controls the auto-hiding behavior of the top toolbar. When the pin is pointing vertically (pinned state), the bar is locked in place and remains permanently visible. When the pin is rotated by -45 degrees (unpinned state), the bar automatically slides upward out of view when the mouse leaves its area.
3. **Full Screen (Green Arrows Icon)**: Instantly switches the active window into fullscreen mode and back. In fullscreen mode, the arrows point inward (collapse), and in windowed mode, they point outward (expand).
4. **Minimize (Cyan Minimization Icon)**: Minimizes the application window to the taskbar. Restoring it returns the window to its exact previous state (e.g. maximized or fullscreen).
5. **⚙️ OPTIONS**: Toggles the configuration options window. If the window is already open, clicking this button closes it.
6. **📺 NEW WINDOW**: Opens a new, independent, and fully configurable `Auxiliary Window`, perfect for expanding your camera layouts across multiple monitor setups.
7. **ARCHIVE**: Opens an empty `PlaybackWindow` (recordings player) with active timeline and calendar, allowing manual stream and camera channel selections from any configured NVR via the sidebar list.
8. **INSTRUCTIONS**: Opens this manual window (the yellow book button).
9. **📊 STATS Switch**: Toggle switch to slide out the System Statistics monitoring panel from the left screen edge.
10. **Recorder status**: A round button, green when the last check was clean (tooltip *NVR status: OK*) and red when a recorder reported a problem (tooltip *NVR errors detected!*). It is shown while recorder monitoring is on and at least one recorder is saved. Clicking it opens **NVR Status**. Each row shows the recorder, OK or ERROR, the time of the last check, and the problem. **Check now** runs the check again. The first check runs a few seconds after KVision opens, then about every five minutes. Live pictures use a separate connection, so a camera can stay on screen while this check fails. When a status read fails, KVision drops that login and tries once more. A camera with one or two channels that still fails stays off the red button. A recorder with more channels still turns it red. **Offline** on a row stops video, detection, logging and this check for that recorder's cameras until you untick it. What is checked is chosen under **Settings > NVR**.
11. **Grid Lock Switch (Padlock)**: Switch that, when turned ON (highlighted in bright orange), disables grid-resizing actions on the adjacent grid buttons, protecting your active camera layout from accidental changes.
12. **Grid Size Selectors (from 1x1 to 6x6)**: A row of six buttons that lets you instantly define the row and column structure of your viewport (from a single camera 1x1 view up to 36 simultaneous camera feeds in a 6x6 layout). The currently active size highlights in bright orange.
13. **More Options (Hamburger Menu with three lines)**: Button opening the sliding `Layout & Grid Tools` toolbox for advanced grid tuning, geometry adjustments, and debugging options (detailed below).
14. **Preset/View Buttons**: Buttons on the right side of the toolbar for the layouts whose Toolbar tick is on. They follow the order of the Presets list. Clicking a button switches to that layout. The active view highlights in bright light-turquoise.

### Advanced Grid Customization & Ratios (Layout & Grid Tools)
Opening the Hamburger (More Options) menu brings up a specialized layout toolbox. To activate its controls:
1. **Unlock tools pane**: Toggle the "Unlock tools pane" switch at the very top. This is an explicit safety measure to prevent accidental changes to complex layouts.
2. **Custom Window Division (F2 or Press-and-Hold)**: The toolbox displays grid division buttons from 1x1 to 9x9. An extremely advanced feature is the ability to **override and edit division sizes**. If you click-and-hold any grid button with the left mouse button (or focus it and press **F2**), a text box appears. You can type any custom or asymmetrical division (such as `2x3`, `1x4`, etc.) and press Enter. The button is instantly reprogrammed, and clicking it applies your custom layout to the main viewport.
3. **Geometry Ratios**: Allows forcing the grid display to specific aspect ratios:
   * **16:9 Aspect Ratio**: Locks and scales the grid container to widescreen 16:9 format (standard for modern IP cameras).
   * **4:3 Aspect Ratio**: Adapts the grid container to the traditional 4:3 ratio (common in legacy analog/IP cameras).
4. **Grid Operations (Merge Highlighted Cells)**: Access the asymmetric cell merging feature (detailed in Section 9, item 2).

---

## 6. System Statistics Panel (System Stats)

Sliding out from the left edge of the Live View screen, this panel monitors the computer's health and the load generated by the application:
* **Monitored Parameters**:
  * **CPU / RAM**: Usage of the main processor (in % of all cores) and the RAM used directly by the `kvision` process and its related downloader subprocesses.
  * **GPU / VRAM**: Graphics card core utilization (in %) and the amount of VRAM graphic memory occupied by rendering and hardware decoding (supports full listing of GPU processes using the XML parser from `nvidia-smi`).
  * **NETWORK (Net)**: Actual download transfer speed of the application from all active live players, archive players, and recording download processes.
  * **STREAMS / DECODE**: The number of live FFmpeg streams and Hikvision SDK playback sessions open right now; the busiest CPU core of the machine; the GPU decode-engine load (NVIDIA); and, added up since KVision started, the frames thrown away because a decoder's queue was full, and the demux or decode hiccups.
  * **HISTORY**: One sample a second is kept in a rolling window — 5, 15, 30 or 60 minutes, switched with the small button in the panel's title bar — even while the panel is closed. The charts open with the whole window already drawn (averaged over their slots when the window is longer) instead of starting from zero.
* **Multithreading (Stutter-Free)**: Process and GPU data collection runs on a separate system thread (`StatsWorker`). This prevents any micro-stuttering in video rendering (no frame drops).
* **Pin Feature**: Clicking the **"Pin"** button (pin icon) locks the panel in its expanded state.
* **Aesthetics**: The charts feature bright, neon-green borders, a gradient fill under the chart curve, and a balanced 35% background transparency to ensure text readability.

---

## 7. Playback Archive Player

Available by clicking the clock/play icon next to a specific camera or recorder. It allows for simultaneous viewing of archived recordings from multiple Hikvision cameras in full time synchronization.

### Timeline & Controls:
* **Quick Start (15 minutes back)**: When opening the archive from the live view, the player automatically starts from a moment falling **exactly 15 minutes before the current system time** (instead of starting at midnight). This allows for immediate viewing of an event that just occurred.
* **Navigation**: The timeline can be scrolled left and right by dragging it with the left mouse button.
* **Zoom (Scaling)**: You can smoothly change the timeline scale with the mouse scroll wheel (or Zoom buttons) – from viewing the entire day down to a precise 10-minute precision view.
* **Quick Zoom Shortcuts**: The bottom control bar features dedicated circular icon buttons to instantly scale the timeline view:
  * **„1h” icon**: Zooms the timeline in for detailed inspection over a 1-hour span.
  * **„8h” icon**: Zooms the timeline to display an 8-hour span.
  * **„24h” icon**: Resets zoom to fit the full 24-hour day on a single screen.
  * **Center (Target) icon**: Immediately centers the timeline so that the red playback indicator is exactly in the middle of the screen (replacing the old text button).
* **Date Navigation (Calendar & Days)**: Controls beside the displayed date allow rapid jumps:
  * **„<” (Previous Day)** and **„>” (Next Day)** buttons: Let you jump 24 hours back or forward instantly without opening the calendar dialog.
  * **Calendar icon**: Opens the calendar popup to select a specific date.
  * **Refresh icon**: Forces a fresh search of recordings. Clicking it sweeps the local cache of recording availability segments for all active channels and submits new queries to the NVR, which is highly useful to load files recorded just a few moments ago (replacing the old text button).
  * **Today (Today's date/number) icon**: Instantly jumps back to the current day (replacing the old text button).
* **Playback Speed Shortcuts**:
  * **„1x”, „2x”, and „4x” icons**: Instantly change the playback speed multiplier.
* **VCR Jump Buttons**:
  * **„15”, „45”, and „60” icons with circular arrows**: Let you quickly skip backward or forward by the specified number of seconds.
* **Recording Availability Bars**: Colored bars representing the found video segments on the recorder's disk are rendered below the timeline. A caching system prevents them from flickering while dragging.
* **Auto-follow (Indicator tracking)**: The playback indicator (vertical red line) is constantly monitored. If the indicator goes outside the visible range of the timeline, the view will automatically scroll to center it. This option is intelligently locked during manual indicator dragging by the user.

### Camera Side Panel in Playback Window
A vertical side list on the right edge of the player lists all configured NVRs and their camera channels:
* **Toggling Channels**: Clicking any camera channel on the list adds it as an active playback slot on the timeline (spawning a video player). Clicking it again removes the channel.
* **Channel Context Menu**: Right-clicking an active video slot in the playback grid opens a menu to:
  * Toggle video quality (Main Stream / Sub Stream).
  * Close/remove the active player from the archive playback.

---

## 8. Downloading Recordings (Downloader)

From the Playback Archive window, you can download selected segments of recordings directly to your computer's drive as MP4 files:
1. Click the download icon (downward arrow) next to the selected camera.
2. Select the time range (start and end of the recording).
3. Select the destination file save location.
4. Click **Download**.

### Advanced Download Features:
* **Sequential Segment Downloading (1GB parts)**: The program automatically splits your time range query into physical file segments (roughly 1GB each on the NVR drive) and downloads and converts them one by one (using temporary `.pspart` files that are converted directly to `.mp4` format). This ensures highly stable downloads of long duration ranges without memory overflow or FFmpeg conversion hangs.
* **Overall Progress Visualization**: The progress bar (bright teal color) displays the overall download progress for the camera across all segments. The status text overlaid on the progress bar shows the current part and percentages, e.g., `Downloading part 1 of 3... 45% (Overall: 15%)`, with an outline styling to guarantee legibility on any background.
* **Filename IP Cleaning**: Video filenames (and live/archive snapshots) are automatically stripped of NVR/DVR IP addresses to keep them clean and human-readable (e.g. `4_Wejscie_glowne_2026-06-15.mp4` instead of `<RECORDER_IP>_4_Wejscie...`).

---

## 9. Advanced Settings and Customization in Options Window

The options window (`SideBar`, opened with the **Options** button) shows five tabs: **Recorders**, **Presets**, **Settings**, **Import / Export** and **Changelog**. The two items numbered 1 and 2 below are not tabs: the viewport settings are a dialog opened from a tile's right-click menu (**Quick tools > Change settings**), and the layout tools are the window opened by the hamburger button on the top bar.

### 1. Viewport Settings (right-click a tile > Quick tools > Change settings)
A dialog for the selected tile. It has:
* **Active Stream Connection**: the **Primary Stream URL** (RTSP/ONVIF) and a **Secondary Backup URL** for manual configurations. A camera that came from a recorder fills these in for you.
* **Channel Options**: the **FFmpeg options** for this tile, and a tick box that leaves this tile out of global FFmpeg changes.
  * **Tip:** for the fastest stream connection and maximum stability over RTSP, the recommended parameters are:
    ```ini
    -analyzeduration 100000 -probesize 500000 -fflags +nobuffer -flags low_delay -rtsp_transport tcp
    ```
    Do not set `-analyzeduration` to `0` on a stream with no audio. The Settings note below says why.
* Muting and unmuting a tile is done with the **M** key or the speaker button on the tile, not in this dialog.

### 2. Layout & Grid Tools (hamburger button on the top bar)
A window with three groups: **Window Division**, **Geometry Ratio** and **Grid Operations**. Turn on its unlock switch first. See Section 5 for the details.
* **Asymmetric Cell Merging (Merge Highlighted Cells)**: Hold **Ctrl** or **Shift** and click to select several adjacent tiles, or hold **Shift** and use the **Arrow keys**, then click "Merge Highlighted Cells" to join them into one larger tile. This allows asymmetric layouts, for example one large camera with smaller feeds around it.

### 3. Recorders tab (Server Icon)
Full configuration manager for connections to Hikvision NVR/DVR devices (described in detail in Section 3). **Add Stream** on this tab saves an `rtsp://`, `http://` or `https://` address as a one-channel camera in that same list.

### 4. Presets tab (Star Icon)
One list of your saved grid layouts. A tile on any layout can hold a camera from any recorder. You can add an empty layout, rename one, show or hide it on the top bar (the Toolbar tick), or switch to it. Click a layout to select it, then use the round up and down buttons on the left of the list to move that one row. The layout buttons on the top bar follow that list order. Moving a row past the layout on screen still switches that picture. The temporary grid from the toolbar grid-size buttons is not in this list.

### 5. Settings tab (Gear Icon)
This page has six sections, chosen with the buttons along its top: **Detection**, **NVR**, **Cameras and display**, **Audio**, **General** and **Camera Tools**. Detection is described in Section 13 and Camera Tools in Section 14. Global application settings include:
* **Allow running multiple instances**: Checking this box allows launching multiple parallel copies of the KVision process (by default, it restricts runs to a single active instance).
* **Auto-collapse settings**: Customizes sliding animation timing for the top bar and statistics panel.
* **Allow swapping viewports**: The checkbox *„Allow swapping viewport places”* enables you to rearrange camera positions on the grid on the fly (Right-click source tile -> Choose "Swap viewports" -> Left-click target tile).
* **Right-click permissions**: Switches to lock/unlock interactive controls in the right-click context menu (Enable context menu, Allow swapping viewports, Enable 'Remove camera' option, Allow changing viewport settings, Enable stream Main/Sub quality selection).
* **Hide Cursor in Full Screen**: The checkbox *„Hide cursor in full screen mode”* automatically hides the mouse cursor after a brief inactivity period during fullscreen viewing to ensure an unobstructed view.
* **Language selection**: Interface language. English is the only language shipped in this version, so the choice has no other effect.
* **UI Preferences**: Hide/show viewport status labels or control badges (such as auto-hiding the control overlays in the bottom right corner of tiles unless hovering).
* **Default FFmpeg Options & Bulk Update**: Allows configuring global FFmpeg options applied to new viewports (recommended: `-analyzeduration 100000 -probesize 500000 -fflags +nobuffer -flags low_delay`).
  * **Recommendation:** if your streams are slow to switch, or you are carrying settings over from an old KVision, change `-analyzeduration 0` to `-analyzeduration 100000` in the global settings and click "Update all cameras". Setting `0` on streams without an audio track causes delays in switching because FFmpeg will block for a hardcoded 5-second timeout waiting for audio packets. Setting a very low value (e.g., 100000 microseconds = 0.1s) completely resolves this issue while maintaining instant switching.
  * **Update all cameras button**: The **Update all cameras** button applies these global options to all configured viewports.
  * **Low-latency flags (`nobuffer`, `low_delay`)**:
    * `-fflags +nobuffer` adds the flag that disables internal demuxer packet buffering, so the picture does not lag behind, and leaves FFmpeg's other flags in place. It might cause stuttering if your network connection to the camera is unstable.
    * `-flags low_delay` tells the decoder to output frames immediately, but can cause brief artifacts/smearing in streams that use B-frames under rapid movements.
  * **Override checkbox**: You can exclude specific viewports from global updates or dynamic defaults by ticking the option that leaves out global FFmpeg changes in the individual Viewport Settings dialog. Useful for troubleshooting stuttering cameras.

**Settings > NVR** chooses what the recorder-status button looks for:
* **Check Hikvision NVR error status**: turns the check and the toolbar button on. The button is hidden when this is off.
* **Monitor offline status and login errors**, **Monitor CPU overload (>85%)**, **Monitor recorder hardware errors**, **Monitor hard disk faults/abnormalities**, **Monitor unformatted hard disks**, and **Monitor full hard disks (loop coverage disabled)**.

**Settings > Audio**:
* **Disable audio entirely**: KVision does not open the audio track. No tile has sound, and the dropped-audio message cannot appear. Muting a tile only turns that tile's speaker off, so the message can still appear while tiles are muted.
* **Repair Hikvision live audio**: **Choose cameras...** lists the cameras. Tick a camera whose live sound was dropped. **Find broken audio** reads each camera's live audio description and ticks only a broken AAC line. A correct description, and a camera with no audio, stay unticked. The result lists the encoding and marks a broken line in red. Only a ticked camera is repaired, and only on this computer. Every other camera stays as it is. The cameras and their recordings are not changed.
* If a camera's live audio keeps failing, KVision shows **Live audio was dropped** once during that run and names the camera. One brief failure does not raise it. **Choose cameras** opens the same list. **Not now** leaves the list unchanged.
* **Maximizing camera to full screen does not unmute**: unticked by default, so maximizing a camera turns its sound on. Tick it to leave the tile muted.
* **Turn off the Talk button (two-way audio)** hides the microphone button on the tiles. **Talk microphone** chooses which microphone that button uses.

### 6. Import / Export tab
Saves your recorders, layouts and settings to a configuration file (`.conf` / `.ini`) and loads one back. Snapshot and video paths are adapted to this computer on import. **Open configuration folder** opens the folder where KVision keeps its settings, logs and event pictures (`~/.config/KVision`).

### 7. Changelog tab (Clock/Document Icon)
Presents an interactive timeline showing the complete release history, updates, bug fixes, and feature additions of KVision, ensuring you have direct access to program updates details.

---

## 10. Keyboard Shortcuts and Mouse Controls

### Keyboard shortcuts:
| Key / Shortcut | Action |
|---|---|
| **F** / **F11** | Toggle Full Screen mode. |
| **M** | Mute / unmute audio (works for the active camera with audio). |
| **Space** | Play / Pause playback in the Playback Archive window. |
| **Alt + 1** to **Alt + 9** | Quick switch to a preset/layout at indices 1 to 9. |
| **Alt + Left Arrow** | Quick switch to the previous preset/layout in the collection. |
| **Alt + Right Arrow** | Quick switch to the next preset/layout in the collection. |
| **Arrow keys (Up/Down/Left/Right)** | Navigate and move the active focus/selection between camera viewports. |
| **Shift + Arrow keys** | Select multiple adjacent camera viewports simultaneously (used for cell merging, etc.). |
| **Ctrl + N** | Open a new, independent auxiliary window. |
| **+** / **-** | Zoom in / Zoom out (PTZ-capable Hikvision cameras). |
| **Shift** (drag marquee) | Force marquee selection to lock in a 16:9 aspect ratio during interactive zoom. |
| **Esc** | Exit Full Screen mode / cancel active viewport selection. |

### Mouse interaction:
* **Left mouse button**:
  * **Double-click** on a camera viewport in the grid maximizes it to full screen. Another double-click restores the grid view.
  * Drag the timeline in the Playback window to navigate.
* **Middle Mouse Button (Scroll wheel click & drag)**:
  * Drag to pan and move the digitally zoomed/magnified image around the viewport field of view (works in Live, Archive, and Mini-player).
* **Right mouse button (Context Menu)**:
  * Opens a quick settings menu for the selected viewport (allows removing the camera from the grid, changing between Main/Sub streams, or accessing individual display parameters).
* **Mouse Scroll Wheel**:
  * On the live camera page, scrolls between the saved layouts shown on the top bar (the same views as the preset buttons). Scrolling up moves to the next view on the right, scrolling down moves back, and the list wraps around. Hidden presets are skipped. A short label shows the layout name. Hold **Ctrl** while scrolling over a camera to zoom that view instead. While a camera is maximized (double-click), the wheel stays on that layout and moves to the next or previous camera in it, skipping empty cells. Scrolling up moves to the next camera, scrolling down to the previous, and the list wraps around.
  * Adjusts scale (Zoom) of the timeline in the playback archive player.

---

## 11. Taking Snapshots and Path Configuration

The application allows you to quickly capture high-quality snapshots from any camera viewport in both Live View and Playback Archive mode.

### Taking Snapshots:
1. A camera icon overlay button is available in the bottom-right corner of each viewport (detailed in Section 4).
2. Clicking the camera icon captures the frame and saves it as a JPEG image (quality 98 - virtually lossless).
3. A successful capture is confirmed by the camera icon flashing orange (`#ff7a00`) for exactly 1 second.
4. **Full Resolution**: In Playback Archive mode, snapshots are saved at the stream's full native source resolution directly from the decoder's frame buffer, regardless of the active viewport size on screen or display scaling.
5. **Folder and filename**: Snapshots use the same layout as downloaded video. They are saved under the snapshots folder in a `yyyy-MM-dd` directory, named `Recorder_Channel_Camera_yyyy-MM-dd_HHmmss.jpg`. Archive snapshots use the playhead time. Live snapshots use the current time.

### Saving Path Configurations:
1. Go to the **Settings** tab (gear icon in the options window).
2. Under the **Saving** section, you can configure the default paths:
   * **Default snapshots path**: Folder where snapshots will be saved (defaults to `~/Pictures/CCTV`).
   * **Default recordings path**: Folder where downloaded MP4 videos will be saved (defaults to `~/Videos/CCTV`).
3. Clicking the `...` browser button opens your operating system's native folder selector (Breeze in KDE).
4. **Browser Button Behavior**: The directory picker opens precisely at the path typed in the text field (if it exists). If the field is empty, invalid, or pointing to a folder you don't have access to, the dialog falls back and opens at your home directory (`~/`).

### User Interface Settings (UI):
1. Go to the **Settings** tab (gear icon in the options window) or open the **Options** window.
2. In the **User Interface Settings** section, you can customize the visibility of elements overlaid on the camera tiles:
   * **Show channel status in the top left corner of the viewport** (default enabled) — Displays stream loading, playing, and connection status information. The small badge reads like `MAIN | RTSP | H.265 | 30 FPS | 4.2 Mbps`: which stream the tile plays, how it is fetched, **the video encoding (H.265, H.264 and so on)**, the frame rate and the bit rate. The encoding is read from the stream KVision plays, so it shows once the video is up, and is left out for a tile that plays through the Hikvision SDK player or for a quick playback, which do not report it.
   * **Show camera info in the bottom left corner of the viewport** (default enabled) — Displays the camera name retrieved from the Hikvision recorder.
   * **Show control icons in the bottom right corner of the viewport only when hovering** (default enabled) — Automatically hides the control button panel (snapshot, archive, 1:1 pixel-to-pixel, region zoom) when the mouse cursor is outside of that specific camera viewport. The icons appear instantly as soon as you move your mouse over the viewport (no click required) and disappear when leaving, maximizing the visibility of your camera streams.
   * **Show info fields only when hovering** (default disabled) — Analogous option that hides the status on top-left and name on bottom-left of viewports, displaying a completely clean camera stream unless the cursor is moved over that specific camera tile.

---

## 12. The Right-Click Menu and Quick Tools

Right-click a camera tile to open its menu. Some entries show only when they apply (for example, the web page entry shows only for a Hikvision camera) or when the matching permission is on in Settings. A 4:3 picture in a 16:9 tile fills the tile on its own, so there are no black bars beside it. A picture only a little wider than its tile, such as a panoramic that does not match the tile exactly, fills the tile the other way, so there are no bars above and below. A picture more than about a third wider than the tile keeps those bars. A 16:9 picture in a matching tile is left at its own shape, and a 4:3 layout is left alone.

* **Replace camera / Add camera**: put a different camera on this tile (see Section 3).
* **Remove camera**, **Swap viewports**, **Stream selection** (Auto, MAIN only, SUB only), **Playback** and **Snapshot**.
* **Open camera web UI**: opens the camera's own web page in your browser (the browser can be chosen in Settings > General > Web browser).
* **Detection frame**: turns the frame and label on or off for this camera only. It works only when the detection frame is switched on in Settings > Detection.
* **Detection events...**: opens the detection log for this camera (Section 13).
* **Quick tools**: a sub-menu with:
  * **Reload**: restarts this tile's stream.
  * **Check detection setup...**: a read-only check of what the camera reports about detection (metadata, zones, rules, where each rule lives, whether it notifies the Surveillance Center). It changes nothing and lists what is missing.
  * **Change settings**: the Viewport Settings dialog (Section 9, item 1).
  * **VCA > Show VCA Line Rules**: KVision draws that camera's rule lines and zones on the picture, in blue, and red while that rule is in alarm. They are read from the camera's smart data, so they show on the main stream and the sub-stream, including a panoramic camera that has no switch for drawing lines into the video. The camera is not changed. The tick is remembered for that camera. Lines are not drawn while the tile is zoomed or at 1:1.
  * **VCA > Target Boxes**: draws a box on every person or vehicle the camera is tracking, green, and red while that target sets off a rule. Same smart data, and the camera is not changed. The tick is remembered per camera.
  * **Noise filter (camera sound)**: the camera's own "Environmental Noise Filtering" switch. A tick shows when it is on. It is an on/off switch only.
  * **Activate Flashing Light**: makes the camera's built-in light flash. The camera stops it after its own programmed time. Some newer cameras (a G3 was tried) accept the command but have no on-demand strobe, so nothing flashes; the tooltip says so.
  * **Play Warning Message**: makes the camera play the sound, volume and number of times already set on it (its web page: Event > Audio Alarm). **It is loud.**
  * **Reboot Camera**: restarts this one camera after you confirm. The camera is offline for a minute or two and records nothing meanwhile. A recorder is never restarted from here.

The camera controls in Quick tools show only on a camera that reports the feature, and each one changes only the camera you right-clicked.

---

## 13. Detection Events: Frames, Log and Pictures

Cameras and recorders tell KVision when they detect something. KVision uses those reports in three ways: a **frame and label on the tile**, a **log line**, and a **picture**. They are set up in **Settings > Detection**.

### What the tile shows
When a camera reports a target, the tile shows a frame with a label, for example **HUMAN - INTRUSION**. The first word is what the camera thinks it saw. The second is which rule fired.
* **Target words:** HUMAN, VEHICLE, ANIMAL, or **OTHER** when the camera could not classify the target.
* **Rule words:** LINE, INTRUSION, ENTER, EXIT or SMART (another smart event).
* **MOTION** alone is plain motion: something moved, and the camera named neither a target nor a rule.
* **FACE DETECTED** (a purple frame) shows when a camera with face detection reports a face.
* A new line, intrusion, entrance or exit report holds the label for about ten seconds against plain motion, so a motion report does not replace it.
* The frame stays for the number of seconds you choose (Settings > Detection) after the last report.

### Settings > Detection
* **Detection frame**: turns the frames on, sets how long they stay, and lets you pick which kinds of report and which targets draw a frame. These choices change **only the frame and label on the tile** (and the Frames.log file). They do **not** change what the detection log or the saved pictures hold.
* **Where detection events come from**: for a camera behind a recorder, take its reports from the camera itself or through the recorder. The list can mix the two per camera. Each camera is read from one place only, so nothing is logged twice.
* **Plain motion**: some cameras (a panoramic camera, for example) can only say that something moved. Two tick boxes choose whether to write it to the log (one line when movement starts, the next only after 10 seconds of stillness) and whether to show a MOTION frame. Both are off by default.
* **Detection log and pictures**: keep logging after KVision is closed (a small background service), and how many event pictures are kept per camera (the newest ones; older ones are deleted).

### The detection log window
Open it from a tile's right-click menu (**Detection events...**). Each line shows the time, the target, the type, the camera, its address, the source (Camera or NVR), a picture button and a play button. The window opens with the newest 10 entries. **Load 25 more** adds the next 25 older ones.
* **Top row (what to show):** *Only this camera*, a time range, and **Targets** and **Types** buttons that open lists of tick boxes. Tick one or several to show only those; nothing ticked shows everything. Each button shows how many are ticked, and **Clear** unticks them all. The lists stay open while you tick, and the log is changed once, when you close a list.
* **Bottom row (what to leave out):** **Targets** and **Types** buttons that open lists of tick boxes. Tick what you do not want in the list. For example, tick *Unnamed motion* to hide motion that did not say what moved. The list stays open while you tick several; press Escape or the button again to close it, and the log is changed once, when the list closes. Each button shows how many items are ticked, and **Clear** unticks them all. The ticks reset when the window is opened again.
* **Picture button:** shows the picture saved for that event. That row is highlighted, and the next and previous picture move the highlight to the row of the picture on screen. A report of plain motion with no target has no picture, and a labelled motion report gets a still asked for from the camera (at most one every 30 seconds per camera).
* **Who draws the box on that picture.** On the camera's own page, under VCA (or Event) > Smart Event > General Settings > Metadata, the switch **Overlay Rule Frame and Target Frame on Background Picture** chooses. Leave it **off** when you look at pictures in KVision. The saved photo stays plain, and KVision draws the red target box and the orange zone. **Target and zone** on the picture hides or shows that drawing. Turn the switch **on** only when those same pictures are also opened outside KVision (an email, FTP, or the camera's own page). The camera then burns its outline into the file, KVision sees that outline and adds nothing, and the tick is hidden. KVision's own **VCA > Show VCA Line Rules** draws the live lines on the tile and does not use that switch.
* **Play button:** opens the recording about 10 seconds before the event. It is dimmed when the recorder no longer has video that old.
* **Log words:** "Other" in the log means the same as OTHER on the tile: the camera named a target KVision could not class as human, vehicle or animal.

### Log files
These are kept in `~/.config/KVision/logs` (**Open configuration folder** in the Import / Export tab opens it):
* `Detection.log`: the detection log shown in the window.
* `OtherEvents.log`: events a camera sent that KVision has no type for (written with the camera's own type name). Heartbeats and port changes are left out.
* `Frames.log`: each frame the tile showed, with its words and tile number.

---

## 14. Camera Tools (Backup, Clock, Firmware, Reboot)

**Settings > Camera Tools** works on one camera at a time, using that camera's own address (not the recorder's). A camera uses the recorder's login unless you give it its own username and password. KVision tries a login once and never with a blank password.

* **Target boxes and VCA lines**: *Choose cameras...* opens a list with a tick for target boxes and a tick for VCA lines. A tick takes effect at once and is the same tick as right-click > VCA on a tile. KVision draws them. The camera is not changed.
* **Video stream**: *Choose streams...* sets **Auto**, **Main**, **Sub** or **Third** for each camera. The choice is used on every layout that shows that camera, including a layout it is added to afterwards. Auto uses the sub-stream on a multi-camera layout and the main stream when that tile is alone. Each layout that already shows the camera is listed under it with **Exclude**. A ticked layout keeps its own stream. Right-clicking a stream on a tile sets that tile and ticks Exclude for that layout. Clearing the tick puts that layout back on the camera's choice.
* **Camera backup**: *Back up* saves the picked camera's configuration to the `backups` folder next to the settings file, with a small `.json` file beside it. *Back up all cameras* does every camera in turn. *Restore* puts a chosen backup back on the camera it came from only: the serial number must match, a fresh backup is taken first, and nothing is sent if that fails. The camera restarts afterwards.
* **Camera settings (read only)...**: reads a camera's device and firmware, time and network, video streams, picture settings, detection rules and what each does, the hours of its speaker and light, memory card, recording and users (names only). A two-lens camera is read once per lens, and those sections are named with the lens. *All cameras* reads every camera into one table, and a two-lens camera's Motion, Intrusion and Line crossing cells name each lens. Closing the window stops that read. Nothing in it can change a camera.
* **Camera clock and firmware**: *Check* shows one camera in the box. *Check all* opens a window with one card per camera, filled in as each camera answers, with a count of how many are fine and how many need a look. It compares each camera's clock with this computer's and shows its firmware version, build date and model. A clock more than two minutes off is flagged. It also shows a note about the newest firmware for that model and a button that opens Hikvision's own page for it. KVision never installs firmware.
* **Reboot a camera**: restarts a camera that is not on a tile (the right-click **Reboot Camera** does the same for a tile). You are asked first.
* **Troubleshooting > Unstick event detection**: if a camera accepts connections and heartbeats but sends no detection events, this turns the "center" notification method off and back on for each event of the chosen camera or channel, then restores the original settings.
