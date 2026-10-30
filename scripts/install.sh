#!/usr/bin/env bash
# Install NomadFS from a GitHub release for this user, replacing the running
# copy (the same places as install-local.sh, without building anything):
#   ~/.local/bin/nomadfs-gui                          the app (AppImage, x86_64)
#   ~/.local/bin/nomadfs                              the command line node
#   ~/.local/share/applications/com.foreachdeveloper.nomadfs.desktop
#   ~/.local/share/icons/hicolor/*/apps/com.foreachdeveloper.nomadfs.png
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/nomadfs/main/scripts/install.sh | bash
#   scripts/install.sh                    the latest release
#   VERSION=0.3.11 scripts/install.sh      that release
#   NO_RESTART=1                          leave the app stopped
#   NO_CLI=1                              skip the command line node
#   NO_DESKTOP=1                          skip the launcher entry and icons
#
# Every file is checked against the release's SHA256SUMS. On aarch64 only
# the command line node is installed (there is no ARM AppImage). An
# installed AppImage updates itself from then on (About > Updates).
set -euo pipefail

repo=https://github.com/highercomve/nomadfs
for tool in curl sha256sum; do
  command -v "$tool" >/dev/null || { echo "error: $tool is needed" >&2; exit 1; }
done

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "error: no NomadFS build for $(uname -m)" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "error: this installs the Linux build" >&2; exit 1; }

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

want_app=1
[ "$arch" = x86_64 ] || want_app=
[ -z "${NO_CLI:-}" ] && want_cli=1 || want_cli=
[ -n "$want_app$want_cli" ] || { echo "Nothing to install (NO_CLI on $arch)" >&2; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fetch() { # <asset>
  echo "Downloading $1"
  curl -fSL --progress-bar -o "$tmp/$1" "$base/$1"
}

echo "Installing NomadFS $version ($arch)"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
files=()
[ -n "$want_app" ] && files+=("nomadfs-gui-$version-x86_64.AppImage")
[ -n "$want_cli" ] && files+=("nomadfs-$version-$arch-linux")
for f in "${files[@]}"; do
  fetch "$f"
  grep -E "  $f\$" "$tmp/SHA256SUMS" >"$tmp/$f.sum" || { echo "error: $f isn't in SHA256SUMS" >&2; exit 1; }
  (cd "$tmp" && sha256sum --quiet -c "$f.sum") || { echo "error: $f doesn't match its checksum" >&2; exit 1; }
done
appimage="$tmp/nomadfs-gui-$version-x86_64.AppImage"

# Stop the running copy (the AppImage runtime and the app inside it); it
# unmounts its mount first, on SIGTERM.
if [ -n "$want_app" ] && pgrep -x nomadfs-gui >/dev/null; then
  echo "Stopping the running NomadFS"
  pkill -x nomadfs-gui || true
  for _ in $(seq 50); do pgrep -x nomadfs-gui >/dev/null || break; sleep 0.1; done
  pkill -9 -x nomadfs-gui 2>/dev/null || true
fi

mkdir -p ~/.local/bin
if [ -n "$want_app" ]; then
  install -m755 "$appimage" ~/.local/bin/nomadfs-gui
  echo "Installed the app ($(du -h ~/.local/bin/nomadfs-gui | cut -f1)) to ~/.local/bin/nomadfs-gui"
fi
if [ -n "$want_cli" ]; then
  install -m755 "$tmp/nomadfs-$version-$arch-linux" ~/.local/bin/nomadfs
  echo "Installed the command line to ~/.local/bin/nomadfs"
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
