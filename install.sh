#!/usr/bin/env bash
# KVision installer for Debian, Ubuntu and Linux Mint.
#
#   ./install.sh              install dependencies, build, add an application-menu entry
#   ./install.sh --update     pull the latest version, rebuild, refresh the menu entry
#   ./install.sh --uninstall  remove the menu entry and the build (keeps this folder and your settings)
#
# Only the dependency step uses sudo. KVision itself is installed for the current user.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
DESKTOP_FILE=$DATA_HOME/applications/kvision.desktop
ICON_FILE=$DATA_HOME/icons/hicolor/256x256/apps/kvision.png
LOG=$ROOT/install.log

PACKAGES=(
    build-essential cmake git pkg-config
    qtbase5-dev qtdeclarative5-dev qtmultimedia5-dev qtquickcontrols2-5-dev
    qttools5-dev libqt5svg5-dev libgtest-dev
    qml-module-qtquick-controls2 qml-module-qtquick-layouts
    qml-module-qtquick-window2 qml-module-qtquick-dialogs
    qml-module-qt-labs-settings qml-module-qt-labs-platform
    qml-module-qt-labs-folderlistmodel qml-module-qtmultimedia
    qml-module-qtgraphicaleffects libqt5multimedia5-plugins qtwayland5
    ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
    libswresample-dev libavdevice-dev libva-dev libgl-dev libglx-dev libx11-dev
)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

check_system() {
    [ "$(id -u)" -ne 0 ] || fail "Do not run this as root. Run it as your normal user; it asks for your password only when it installs packages."
    [ -f "$ROOT/CMakeLists.txt" ] && [ -d "$ROOT/src" ] || fail "Run this script from inside the KVision folder."
    command -v apt-get >/dev/null 2>&1 || fail "This installer supports Debian, Ubuntu and Linux Mint (it needs apt). On another distribution, install the Qt 5 and FFmpeg development packages yourself and run ./kvision (see README.md)."
}

install_dependencies() {
    local missing=() p
    for p in "${PACKAGES[@]}"; do
        dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed || missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        say "All required packages are already installed"
        return
    fi
    say "Installing ${#missing[@]} missing packages (your password is needed once)"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}" || fail "Package installation failed. Check your internet connection and that the 'universe' repository is enabled (sudo add-apt-repository universe), then run ./install.sh again."
}

build() {
    say "Building KVision. This takes a few minutes the first time; please wait"
    {
        cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
        cmake --build "$ROOT/build" -j"$(nproc)"
    } >"$LOG" 2>&1 || {
        tail -n 25 "$LOG" >&2
        fail "The build failed. The full log is in $LOG"
    }
    [ -x "$ROOT/build/kvision" ] || fail "The build finished but the program was not created. See $LOG"
}

add_menu_entry() {
    say "Adding KVision to your applications menu"
    mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_FILE")"
    cp "$ROOT/images/256.png" "$ICON_FILE"
    cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=KVision
GenericName=Video streams viewer
Comment=Live Hikvision and RTSP camera walls, playback and PTZ
Icon=kvision
Exec="$ROOT/kvision"
Path=$ROOT
Terminal=false
Categories=AudioVideo;Video;Viewer;
Keywords=cctv;camera;hikvision;nvr;viewer;
StartupWMClass=kvision
EOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
}

finish() {
    local version
    version=$("$ROOT/build/kvision" --version 2>/dev/null | head -n1 || true)
    say "Done${version:+: $version}"
    echo "Open KVision from your applications menu (search for \"KVision\"), or run:"
    echo "    $ROOT/kvision"
    echo
    echo "Tip: when you add a Hikvision recorder, set RTSP Transport to TCP if video stutters or fails."
    echo "Keep this folder where it is; the menu entry points to it."
}

do_update() {
    check_system
    [ -d "$ROOT/.git" ] || fail "This folder is not a git clone, so it cannot update itself. Download the newest release from https://github.com/optio50/KVision/releases instead."
    if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
        fail "You have local changes in this folder. Commit or discard them, then run --update again."
    fi
    say "Fetching the latest version"
    git -C "$ROOT" pull --ff-only || fail "Could not update. Check your internet connection."
    install_dependencies
    build
    add_menu_entry
    finish
}

do_uninstall() {
    say "Removing the menu entry and build files"
    rm -f "$DESKTOP_FILE" "$ICON_FILE"
    rm -rf "$ROOT/build" "$LOG"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
    echo "Removed. This folder and your settings (~/.config/KVision) were left alone."
    echo "To remove KVision completely, delete this folder too."
}

case "${1:-}" in
    "")          check_system; install_dependencies; build; add_menu_entry; finish ;;
    --update)    do_update ;;
    --uninstall) do_uninstall ;;
    -h|--help)   usage ;;
    *)           usage; exit 2 ;;
esac
