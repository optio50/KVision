# KVision

Personal Linux CCTV client for live Hikvision and RTSP camera walls, playback, and PTZ control.

This repository is a private working copy based on the upstream KVision/cctv-viewer project. It keeps the original application and adds the local fixes used on this system.

## Quick start

Install the build dependencies first. `./kvision` builds and launches the application, but it does not install missing packages.

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y build-essential cmake git pkg-config \
  qtbase5-dev qtdeclarative5-dev qtmultimedia5-dev \
  qtquickcontrols2-5-dev qttools5-dev libqt5svg5-dev \
  qml-module-qtquick-controls qml-module-qtquick-controls2 \
  qml-module-qtquick-layouts qml-module-qtquick-window2 \
  qml-module-qtquick-dialogs qml-module-qtqml-models2 \
  qml-module-qt-labs-settings qml-module-qt-labs-platform \
  qml-module-qtmultimedia qml-module-qtgraphicaleffects \
  libqt5multimedia5-plugins \
  ffmpeg libavcodec-dev libavformat-dev libavutil-dev \
  libswscale-dev libswresample-dev libavdevice-dev \
  libva-dev
```

Then clone and run:

```bash
git clone https://github.com/optio50/KVision.git
cd KVision
./kvision
```

The first run configures and builds the application in `build/`, then launches it. Later runs start the already built program immediately.

Do not run KVision as root.

## Recent local changes

- Right-click a cell to add or replace its camera from a recorder picker.
- Mark a playback timeline range and download that range.
- **Snapshot files match downloads.** Pictures stay in the snapshots folder, inside a `yyyy-MM-dd` directory, named `Recorder_Channel_Camera_yyyy-MM-dd_HHmmss.jpg`.

## Build and run

`./kvision` from the repository root is the normal way to run this copy after the dependencies above are installed.

### Manual build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/kvision
```

### Optional system install

```bash
sudo cmake --install build
kvision
```

System installation is optional. `./kvision` from the repository root is the normal way to run this private copy.

## Added since the original clone

These are the standout changes in this copy. The original application already had live grids, playback, snapshots, downloads, auxiliary windows, and layout presets.

### Live view and PTZ

- **Mouse-driven PTZ:** a pad that stays usable in small and large cells, an on-screen keypad for double-digit preset recall and save, and focus near/far controls with tooltips. The entered preset number clears after a successful save.
- **Cell drag-and-swap:** drag cameras between cells, including merged Panovision cells. The right-click swap action remains. The cursor hides in windowed mode, and a startup size guard stops the main window reopening at a tiny saved size.
- **Right-click menu:** right-click an empty cell and choose **Add camera**. The picker lists recorders. A standalone camera is a one-channel recorder and assigns immediately. A multi-channel recorder expands so you can pick one channel. A filled cell offers **Replace camera**, and the green **+** in the camera list still assigns to the focused cell. There is also an **Open camera web UI** entry.
- **Per-tile fullscreen badge:** in a 1x1 grid it toggles the window to fullscreen.
- **Mouse-wheel zoom:** zoom in and out of a box-zoomed viewport, in live view and playback. The zoom selection offset and panning for scaled video are fixed.
- **Third Hikvision stream:** in addition to Main and Sub, with the picture aspect ratio preserved instead of stretching the feed.
- **Channel resolution badge:** info badges hide when idle.
- **18x18 grid:** the grid size goes up to 18x18.
- **Add camera window:** it is always on top and shows added markers.
- **Merged cells:** resizing is fixed, and Panovision merged-cell support is documented.
- **Layout paging:** scroll over the live view to move between saved layouts. Hold **Ctrl** to zoom that camera instead. Layouts can be chosen for the top toolbar instead of showing every preset.
- **Audio:** per-camera mute and volume controls are restored.

### Playback

- **NVR smart events on the timeline:** previous and next event controls jump the playhead between them.
- **Frame advance and speed:** step one video frame at a time for both Hikvision archive playback and RTSP recordings, and play at 6x.
- **Quick playback controls:** seek, event markers, previous/next event and frame step.
- **Timeline range download:** click the timeline twice to set the start and end, then download that range. The download dialog can be closed after a finished transfer. A spinner timer is shown, and the shared session is kept after an event search.
- **Snapshots:** save the full image or the zoomed view. Files are named `Recorder_Channel_Camera_yyyy-MM-dd_HHmmss.jpg` and stored in per-date folders. The time in the name is the camera/NVR time of the frame shown (the recorder's clock in live view), not the PC clock, so it matches the on-screen camera time even when that text is zoomed out of view.
- **Standalone SD-card playback:** falls back to the Hikvision SDK search when the camera stores recordings on its own SD card, and its timing is fixed.
- **Fullscreen playback:** improved.

### Recorder and camera management

- **Recorder cards:** a **Generate Grid** button and working hover text.
- **Recorder cameras window:** tile width is capped.
- **Thumbnails:** grabbing waits for a keyframe and rejects corrupt or flat frames.
- **Per-recorder RTSP transport** (Auto, TCP, or UDP), custom HTTP and RTSP ports, and local camera names that do not change the recorder.

### Platform and settings

- **Clone and run:** `./kvision` configures, builds, and launches the application. The project also builds on Debian 10's GCC 9 and Qt 5.11.
- **Settings import and export** from the side panel, for backing up or moving your configuration to another Linux machine.
- **System statistics** for CPU, RAM, GPU, VRAM, and network use, without stalling video rendering.

## Features

- Live multi-camera grids for RTSP and Hikvision recorders.
- Camera assignment, removal, swapping, and drag-and-drop cell exchange, including merged cells for Panovision cameras.
- Per-camera audio mute and volume controls.
- PTZ pan, tilt, zoom, and mouse-driven preset recall/save.
- Playback with one-frame advance, snapshots, downloads, and auxiliary windows.
- Local camera names and layout presets stored in the application settings.

## Detailed Application Features

### Live View Grid & Viewport Interactions

* **Camera Assignment**: Right-click an empty viewport and choose **Add camera**. The picker lists recorders; a single-channel recorder assigns immediately, and a multi-channel recorder expands so you can pick one camera. Right-click a filled viewport and choose **Replace camera** to change it. The **"+" (Add)** button in the NVR/DVR camera list still assigns to the focused viewport.
* **Viewport Swapping**: Swap camera feeds between two grid viewports by selecting the **"Swap viewports"** option in the right-click context menu of the source viewport and then clicking on the target viewport. Cameras can also be exchanged by dragging one cell onto another, including merged cells.
* **Camera Removal**: Quickly clear/remove a camera stream from any grid viewport using the right-click context menu (**"Remove camera"**) with a safety confirmation dialog.
* **Double-Click to Maximize**: Double-click any camera viewport in the grid to maximize it to full screen. Double-click again to restore the grid layout.
* **Individual Viewport Settings**: Customize RTSP transport protocols, volume levels, and display properties for each viewport individually via the context menu (**"Change settings"**).
* **Multi-Monitor & Auxiliary Windows**: Spawn multiple independent auxiliary viewport windows (via the **"New Window"** button or `Ctrl+N` shortcut) to display different camera grid layouts simultaneously across multiple screens or monitors.
* **Real-Time Bidirectional Configuration Sync**: Instantly synchronizes NVR settings, local camera names, and layouts collection definitions bidirectionally in real-time between the main window and all open auxiliary windows using high-performance file watching (`QFileSystemWatcher`). Window positioning and active layout selection indices remain strictly isolated per window via dynamic, automatic unique window ID allocation.

### Advanced Image Controls & Zooming

* **Interactive Viewport Zooming (Region Selection)**: Enter zoom mode by clicking the magnifying glass icon on any viewport. Click and drag a rectangular marquee over the video stream to crop and zoom into that specific region. Click the icon again to reset the zoom.
* **Proportional Zoom Selection**: Hold the `Shift` key while drawing the zoom rectangle to lock the selection to a 16:9 aspect ratio, preventing distorted crops.
* **Pan Zoom**: Click and hold the middle mouse button (scroll wheel) and drag to freely pan the zoomed-in video stream around the viewport.
* **1:1 Pixel Mapping Mode**: View camera streams in their native pixel-to-pixel resolution without any scaling distortion.
* **Mouse Wheel Zoom (Fullscreen)**: Scale the stream dynamically in fullscreen mode by holding the `Ctrl` key and scrolling the mouse wheel.

### Hikvision NVR/DVR Deep Integration

* **Auto-Discovery**: Enter your NVR/DVR IP address and credentials to automatically discover and list all active camera channels.
* **Automatic NVR Preset Grid**: Click **"Generate Grid"** in the recorders panel to automatically generate a tailored viewport layout (preset) mapping all discovered cameras to an optimal grid size.
* **Dynamic Quality Selection**: Manually toggle between **Main Stream** (high resolution) and **Sub Stream** (low bandwidth/CPU load) for any viewport via the context menu to save system resources and network bandwidth.
* **Local Camera Renaming (Custom Names)**: Clicking the edit icon (pencil) on a camera tile in the recorder channel list allows setting a custom, local name for that camera. The name update is immediately reflected on the tile, live players, and playback timeline. Custom names are saved locally in the settings JSON and do not alter the physical NVR device. The custom name can be reset to the NVR default at any time.
* **PTZ Control**: A scalable, mouse-driven PTZ pad works in both small and large camera cells. Double-digit presets are entered with an on-screen keypad, with Go and Save actions.

### Synchronized Playback Archive

* **Multi-Camera Synchronization**: Play back archived video recordings from multiple Hikvision recorders/cameras simultaneously in perfect time synchronization.
* **Interactive Timeline**: Drag the timeline horizontally to navigate through time. Scale the timeline smoothly with the mouse wheel (from a full 24-hour view down to a 5-minute view).
* **Recording Segment Caching**: Recording segments on NVR storage are cached dynamically to eliminate flickering during timeline manipulation.
* **Timeline Auto-Follow**: The timeline view automatically scrolls to keep the red playback indicator centered, pausing intelligently when the user drags the timeline manually.
* **Manual Re-Center**: Click the **"Center"** button to instantly snap the timeline back to center around the active playback indicator.
* **15-Min Quick Check**: Click the archive icon next to a camera or recorder in the live view to automatically start playback starting **exactly 15 minutes before the current system time**, allowing you to instantly inspect recent events.

### Snapshot Capture & Path Configuration

* **Instant Snapshot Capturing**: Take high-quality, virtually lossless snapshots (JPEG format, quality 98) directly from any active viewport in both Live View and Playback Archive.
* **Camera Icon Overlay**: Viewports feature a subtle camera overlay icon in the toolbar. Clicking it flashes the icon orange (`#ff7a00`) for exactly 1 second to confirm successful capture.
* **High-Resolution Archive Captures**: Playback snapshots are captured at the stream's full native source resolution directly from the decoded frame buffer in memory, bypassing any display scaling or window size constraints.
* **Snapshot folders match downloads**: Snapshots stay in the pictures folder, but use the same date folder and name as downloaded video: `~/Pictures/CCTV/2026-06-11/Yard_1_Front_Door_2026-06-11_143005.jpg`. Archive snapshots use the playhead time.
* **Custom Paths Configuration**: Configure default storage paths for snapshots and downloaded videos in the Settings panel. This copy defaults to `~/Pictures/CCTV` and `~/Videos/CCTV`.
* **Native Directory Browser**: Click the `...` browser buttons to open a native directory selector. The dialog opens at the folder currently shown in the text input, falling back to the user's home folder (`~/`) if the field is empty or points to a non-existent path.

### Archive Recording Downloader

* **Direct MP4 Downloader**: Download segments of archived footage directly to your local drive.
* **Flexible Timeframe Range**: Select precise start/end points for the export.
* **Visual Progress Bar**: Track the download process in real-time, with download bandwidth correctly accounted for in the System Statistics panel.

### Multi-Threaded System Statistics Panel

* **Slide-Out Overlay**: Hover and slide the left edge of the screen to reveal a diagnostic monitoring overlay.
* **Metrics Tracked**:
  * **CPU & RAM**: Total system CPU load (%) and the memory consumed by `kvision` and its download subprocesses.
  * **GPU & VRAM**: Core graphics card utilization and video memory usage (real-time XML parsing of `nvidia-smi` data, filtering only relevant process allocations).
  * **Network Bandwidth**: Live download speed aggregated from all active video players and download subprocesses.
* **Pin Feature**: Click the pin icon to keep the stats panel locked open, or let it slide away automatically.
* **Stutter-Free Video Rendering**: Calculations are performed on a separate thread (`StatsWorker`) to guarantee zero frames are dropped during 60 FPS video rendering.

### Global Application Settings & UI

* **Auto-Collapsing Top Bar**: The top options toolbar automatically collapses when the mouse leaves its boundary to maximize video workspace. This behavior is toggleable in Settings or directly using the pin icon on the top bar.
* **Top Bar Controls**: Compact layout controls on the top bar: fullscreen button (with green visual state), window minimize button (with cyan/blue icon), grid locking switch, options, and a hamburger menu for advanced options.
* **Close Confirmation**: Intercepts both system window close buttons and exit button actions, requesting confirmation before quitting.
* **Custom Layout Presets**: Create custom layout presets with configurable row and column counts (e.g., 2x2, 3x3, 4x4).
* **Global Shortcuts**: Complete control via keyboard hotkeys:
  * `F11`: Toggle fullscreen.
  * `M`: Mute/unmute active viewport audio.
  * `Alt + Left` / `Alt + Right`: Switch layouts.
  * `Alt + 1` to `Alt + 9`: Instant preset switching.
* **Multilingual UI**: Live translation switching across 22 languages.
* **Settings Import / Export**: Dedicated **Import / Export** tab in the side panel (below Settings) allowing one-click backup and migration of configuration files (`*.conf` / `*.ini`) for Linux (`~/.config/KVision/KVision.conf`).
* **Cursor Auto-Hide**: In windowed mode, the cursor and viewport buttons hide automatically and return when the mouse moves.

## Upstream

The original cctv-viewer project was created by Evgeny S. Maksimov. This private repository is maintained separately for local use and is not a request for changes to the upstream project.
