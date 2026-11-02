# KVision

Personal Linux CCTV client for live Hikvision and RTSP camera walls, playback, and PTZ control.

This repository is a private working copy based on the upstream KVision/cctv-viewer project. It keeps the original application and adds the local fixes used on this system.

## Quick start

```bash
git clone --recurse-submodules https://github.com/optio50/KVision.git
cd KVision
./kvision
```

The first run configures and builds the application in `build/`, then launches it. Later runs start the already built program immediately.

Do not run KVision as root.

## Recent local changes

- Added a scalable, mouse-driven PTZ pad for small and large camera cells.
- Added double-digit PTZ preset entry using an on-screen keypad, with Go and Save actions.
- Restored audio mute and volume controls in normal camera cells.
- Added drag-and-drop swapping of cameras between grid cells.
- Merging cells now works for Panovision cameras.
- Added windowed-mode cursor and viewport-button auto-hide.
- Prevented the main window from reopening at a tiny saved size.
- Added the root `./kvision` launcher for clone-and-run startup.

## Build and run

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y build-essential cmake git   qtbase5-dev qtdeclarative5-dev qtmultimedia5-dev   qtquickcontrols2-5-dev libqt5svg5-dev   qml-module-qtquick-controls2 qml-module-qtmultimedia   libqt5multimedia5-plugins ffmpeg libavcodec-dev libavformat-dev   libavutil-dev libswscale-dev libswresample-dev
```

Then:

```bash
./kvision
```

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

## Features

- Live multi-camera grids for RTSP and Hikvision recorders.
- Camera assignment, removal, swapping, and drag-and-drop cell exchange, including merged cells for Panovision cameras.
- Per-camera audio mute and volume controls.
- PTZ pan, tilt, zoom, and mouse-driven preset recall/save.
- Playback, snapshots, downloads, and auxiliary windows.
- Local camera names and layout presets stored in the application settings.

## Upstream

The original cctv-viewer project was created by Evgeny S. Maksimov. This private repository is maintained separately for local use and is not a request for changes to the upstream project.
