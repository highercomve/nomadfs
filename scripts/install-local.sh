#!/usr/bin/env bash
# Build NomadFS from this checkout (the app's AppImage and the command line
# node) and install it for this user, replacing the running copy:
#   ~/.local/bin/nomadfs-gui                          the app (AppImage)
#   ~/.local/bin/nomadfs                              the command line node
#   ~/.local/share/applications/net.nomadfs.app.desktop
#   ~/.local/share/icons/hicolor/*/apps/net.nomadfs.app.png
#
#   scripts/install-local.sh              build and install, restart the app
#   NO_RESTART=1 scripts/install-local.sh leave the app stopped
#   NO_CLI=1                              skip the command line node
#   NO_DESKTOP=1                          skip the launcher entry and icons
#   ORIEL_FORK=~/Code/oriel               build against a local Oriel checkout
#
# Stopping the app unmounts its mount first (it does that on SIGTERM).
# Needs Zig 0.16 and, for the AppImage, what Oriel's Linux build needs
# (GTK 4, WebKitGTK 6).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

fork=()
[ -n "${ORIEL_FORK:-}" ] && fork=(--fork="$(realpath "$ORIEL_FORK")")

version=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' nomadfs-gui/build.zig | head -1)
appimage="nomadfs-gui/zig-out/package/nomadfs-gui-$version-x86_64.AppImage"
rm -f "$appimage"
echo "Building the NomadFS $version app (AppImage)"
(cd nomadfs-gui && zig build package -Doptimize=ReleaseSafe "${fork[@]}")
[ -f "$appimage" ] || { echo "error: $appimage was not produced" >&2; exit 1; }

if [ -z "${NO_CLI:-}" ]; then
  echo "Building the nomadfs command line"
  zig build -Doptimize=ReleaseSafe
fi

# Stop the running copy (the AppImage runtime and the app inside it).
if pgrep -x nomadfs-gui >/dev/null; then
  echo "Stopping the running NomadFS"
  pkill -x nomadfs-gui || true
  for _ in $(seq 50); do pgrep -x nomadfs-gui >/dev/null || break; sleep 0.1; done
  pkill -9 -x nomadfs-gui 2>/dev/null || true
fi

mkdir -p ~/.local/bin
install -m755 "$appimage" ~/.local/bin/nomadfs-gui
echo "Installed the app ($(du -h ~/.local/bin/nomadfs-gui | cut -f1)) to ~/.local/bin/nomadfs-gui"
if [ -z "${NO_CLI:-}" ]; then
  install -m755 zig-out/bin/nomadfs ~/.local/bin/nomadfs
  echo "Installed the command line to ~/.local/bin/nomadfs"
fi

# The launcher entry and icons the packages ship, from the AppImage just built.
if [ -z "${NO_DESKTOP:-}" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  (cd "$tmp" && "$here/$appimage" --appimage-extract 'usr/share/*' >/dev/null)
  share="$tmp/squashfs-root/usr/share"
  apps=~/.local/share/applications
  mkdir -p "$apps"
  # Exec the installed AppImage, wherever ~/.local/bin is on PATH or not.
  sed "s|^Exec=.*|Exec=$HOME/.local/bin/nomadfs-gui|" "$share/applications/net.nomadfs.app.desktop" > "$apps/net.nomadfs.app.desktop"
  for icon in "$share"/icons/hicolor/*/apps/net.nomadfs.app.png; do
    size=$(basename "$(dirname "$(dirname "$icon")")")
    install -Dm644 "$icon" ~/.local/share/icons/hicolor/"$size"/apps/net.nomadfs.app.png
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$apps" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q ~/.local/share/icons/hicolor 2>/dev/null || true
  echo "Installed the launcher entry (NomadFS) and icons"
fi

if [ -z "${NO_RESTART:-}" ]; then
  log="${XDG_STATE_HOME:-$HOME/.local/state}/nomadfs/nomadfs-gui.log"
  mkdir -p "$(dirname "$log")"
  # Detach from the invoking terminal before it exits.
  nohup setsid ~/.local/bin/nomadfs-gui "$@" >>"$log" 2>&1 </dev/null &
  launch_pid=$!
  sleep 2
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    echo "error: NomadFS exited during startup (log: $log)" >&2
    tail -n 20 "$log" >&2
    exit 1
  fi
  echo "Started NomadFS (log: $log)"
fi
