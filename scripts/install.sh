#!/usr/bin/env bash
# Install NomadFS from a GitHub release for this user, replacing the running
# copy. Linux (the same places as install-local.sh, without building
# anything):
#   ~/.local/bin/nomadfs-gui                          the app (AppImage, x86_64)
#   ~/.local/bin/nomadfs                              the command line node
#   ~/.local/share/applications/com.foreachdeveloper.nomadfs.desktop
#   ~/.local/share/icons/hicolor/*/apps/com.foreachdeveloper.nomadfs.png
# macOS (Apple silicon):
#   /Applications/NomadFS.app                         the app (~/Applications
#                                                     when /Applications isn't writable)
#   ~/.local/bin/nomadfs                              the command line node
# Windows: scripts/install.ps1.
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/nomadfs/main/scripts/install.sh | bash
#   scripts/install.sh                    the latest release
#   VERSION=0.3.14 scripts/install.sh      that release
#   NO_RESTART=1                          leave the app stopped
#   NO_CLI=1                              skip the command line node
#   NO_DESKTOP=1                          Linux: skip the launcher entry and icons
#   APP_DIR=<folder>                      macOS: where NomadFS.app goes
#
# Every file is checked against the release's checksums. On Linux aarch64
# only the command line node is installed (there is no ARM AppImage). The
# installed app updates itself from then on (About > Updates), and the
# command line with `nomadfs --upgrade`.
set -euo pipefail

repo=https://github.com/highercomve/nomadfs
command -v curl >/dev/null || { echo "error: curl is needed" >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "error: sha256sum or shasum is needed" >&2; exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "error: no NomadFS build for $(uname -m)" >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin)
    os=macos
    [ "$arch" = aarch64 ] || { echo "error: NomadFS for macOS is built for Apple silicon only" >&2; exit 1; }
    ;;
  *) echo "error: this installs NomadFS on Linux and macOS (Windows: scripts/install.ps1)" >&2; exit 1 ;;
esac

# The latest release: where /releases/latest redirects (no API rate limit).
version=${VERSION:-}
if [ -z "$version" ]; then
  tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$repo/releases/latest")
  version=${tag##*/v}
fi
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "error: couldn't find the latest release ($version)" >&2; exit 1 ;;
esac
base="$repo/releases/download/v$version"

if [ "$os" = linux ]; then
  app_file="nomadfs-gui-$version-x86_64.AppImage"
  cli_file="nomadfs-$version-$arch-linux"
  sums=SHA256SUMS
  [ "$arch" = x86_64 ] && want_app=1 || want_app=
else
  app_file="nomadfs-gui-$version-macos-arm64.app.tar.gz"
  cli_file="nomadfs-$version-aarch64-macos"
  # The workflow that builds on a Mac lists its files apart.
  sums=SHA256SUMS-macos
  want_app=1
fi
[ -z "${NO_CLI:-}" ] && want_cli=1 || want_cli=
[ -n "$want_app$want_cli" ] || { echo "Nothing to install (NO_CLI on $arch)" >&2; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fetch() { # <asset>: downloaded and checked against the release's checksums
  echo "Downloading $1"
  curl -fSL --progress-bar -o "$tmp/$1" "$base/$1"
  local want
  want=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$tmp/$sums")
  [ -n "$want" ] || { echo "error: $1 isn't in $sums" >&2; exit 1; }
  [ "$(sha256 "$tmp/$1")" = "$want" ] || { echo "error: $1 doesn't match its checksum" >&2; exit 1; }
}

echo "Installing NomadFS $version ($os, $arch)"
curl -fsSL -o "$tmp/$sums" "$base/$sums"
[ -n "$want_app" ] && fetch "$app_file"
[ -n "$want_cli" ] && fetch "$cli_file"

mkdir -p ~/.local/bin
if [ -n "$want_cli" ]; then
  install -m755 "$tmp/$cli_file" ~/.local/bin/nomadfs
  echo "Installed the command line to ~/.local/bin/nomadfs"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  ~/.local/bin isn't on your PATH: add it to run \`nomadfs\` by name" ;;
  esac
fi

# ---- macOS ----

if [ "$os" = macos ]; then
  dest=${APP_DIR:-}
  if [ -z "$dest" ]; then
    if [ -w /Applications ]; then dest=/Applications; else dest="$HOME/Applications"; fi
  fi
  if [ -n "$want_app" ]; then
    tar -xzf "$tmp/$app_file" -C "$tmp"
    bundle=$(find "$tmp" -maxdepth 1 -name '*.app' | head -n1)
    [ -n "$bundle" ] || { echo "error: no app in $app_file" >&2; exit 1; }
    name=$(basename "$bundle")
    # Quit the running copy first: it unmounts its volume as it goes.
    if pgrep -f "/$name/Contents/MacOS/" >/dev/null; then
      echo "Quitting the running NomadFS"
      osascript -e 'tell application id "com.foreachdeveloper.nomadfs" to quit' >/dev/null 2>&1 || true
      for _ in $(seq 50); do pgrep -f "/$name/Contents/MacOS/" >/dev/null || break; sleep 0.1; done
      pkill -f "/$name/Contents/MacOS/" 2>/dev/null || true
    fi
    mkdir -p "$dest"
    rm -rf "${dest:?}/$name"
    mv "$bundle" "$dest/$name"
    # Downloaded with curl it carries no quarantine flag; a copy that does
    # would ask on every launch.
    xattr -dr com.apple.quarantine "$dest/$name" 2>/dev/null || true
    echo "Installed the app to $dest/$name"
    if [ -z "${NO_RESTART:-}" ]; then
      open "$dest/$name"
      echo "Started NomadFS"
    fi
  fi
  echo "NomadFS $version is installed."
  exit 0
fi

# ---- Linux ----

appimage="$tmp/$app_file"

# Stop the running copy (the AppImage runtime and the app inside it); it
# unmounts its mount first, on SIGTERM.
if [ -n "$want_app" ] && pgrep -x nomadfs-gui >/dev/null; then
  echo "Stopping the running NomadFS"
  pkill -x nomadfs-gui || true
  for _ in $(seq 50); do pgrep -x nomadfs-gui >/dev/null || break; sleep 0.1; done
  pkill -9 -x nomadfs-gui 2>/dev/null || true
fi

if [ -n "$want_app" ]; then
  install -m755 "$appimage" ~/.local/bin/nomadfs-gui
  echo "Installed the app ($(du -h ~/.local/bin/nomadfs-gui | cut -f1)) to ~/.local/bin/nomadfs-gui"
fi

# The launcher entry and icons the packages ship, from the AppImage.
if [ -n "$want_app" ] && [ -z "${NO_DESKTOP:-}" ]; then
  chmod +x "$appimage"
  (cd "$tmp" && "$appimage" --appimage-extract 'usr/share/*' >/dev/null)
  share="$tmp/squashfs-root/usr/share"
  apps=~/.local/share/applications
  mkdir -p "$apps"
  # Before 0.3.0 the app was net.nomadfs.app: drop its launcher entry and icons.
  rm -f "$apps/net.nomadfs.app.desktop" ~/.local/share/icons/hicolor/*/apps/net.nomadfs.app.png
  # Exec the installed AppImage, wherever ~/.local/bin is on PATH or not.
  sed "s|^Exec=.*|Exec=$HOME/.local/bin/nomadfs-gui|" "$share/applications/com.foreachdeveloper.nomadfs.desktop" > "$apps/com.foreachdeveloper.nomadfs.desktop"
  for icon in "$share"/icons/hicolor/*/apps/com.foreachdeveloper.nomadfs.png; do
    size=$(basename "$(dirname "$(dirname "$icon")")")
    install -Dm644 "$icon" ~/.local/share/icons/hicolor/"$size"/apps/com.foreachdeveloper.nomadfs.png
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$apps" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q ~/.local/share/icons/hicolor 2>/dev/null || true
  echo "Installed the launcher entry (NomadFS) and icons"
fi

if [ -n "$want_app" ] && [ -z "${NO_RESTART:-}" ]; then
  log="${XDG_STATE_HOME:-$HOME/.local/state}/nomadfs/nomadfs-gui.log"
  mkdir -p "$(dirname "$log")"
  # Detach from the invoking terminal before it exits.
  nohup setsid ~/.local/bin/nomadfs-gui >>"$log" 2>&1 </dev/null &
  launch_pid=$!
  sleep 2
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    echo "error: NomadFS exited during startup (log: $log)" >&2
    tail -n 20 "$log" >&2
    exit 1
  fi
  echo "Started NomadFS (log: $log)"
fi
echo "NomadFS $version is installed."
