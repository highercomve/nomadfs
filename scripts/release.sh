#!/usr/bin/env bash
# Builds every asset of a NomadFS release and the signed update manifest
# the apps check (latest.json), for the version in nomadfs-gui/build.zig:
#
#   nomadfs-<v>-x86_64-linux, nomadfs-<v>-aarch64-linux   command line node
#   nomadfs-gui-<v>-x86_64.AppImage, .deb, .rpm            desktop app
#   nomadfs-<v>.apk                                        Android
#   latest.json                                            signed update manifest
#   SHA256SUMS
#
# Usage: scripts/release.sh [out-dir]     (default /tmp/nfs-release-<v>)
#
# The update key signs latest.json; the apps carry its public half
# (update_public_key in nomadfs-gui/build.zig). Keep it out of the
# repository: NOMADFS_UPDATE_KEY, default ~/.config/oriel/keys/nomadfs-update.key.
# Then publish what it prints (gh release create ...).

set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

version=$(sed -n 's/^ *const version = "\(.*\)";/\1/p' nomadfs-gui/build.zig | head -n1)
[ -n "$version" ] || { echo "No version in nomadfs-gui/build.zig" >&2; exit 1; }
for zon in build.zig.zon nomadfs-gui/build.zig.zon; do
  grep -q "\.version = \"$version\"" "$zon" || { echo "$zon isn't at $version" >&2; exit 1; }
done

key=${NOMADFS_UPDATE_KEY:-$HOME/.config/oriel/keys/nomadfs-update.key}
[ -r "$key" ] || { echo "No update key at $key (NOMADFS_UPDATE_KEY)" >&2; exit 1; }
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}

out=$(realpath -m "${1:-/tmp/nfs-release-$version}")
assets=$out/assets
logs=$out/logs
rm -rf "$out"
mkdir -p "$assets" "$logs" "$out/manifests"
base=https://github.com/highercomve/nomadfs/releases/download/v$version

step() { echo "==> $*"; }
run() { # <log name> <command...>: output to the log, shown on failure
  local log=$logs/$1.log; shift
  if ! "$@" >"$log" 2>&1; then
    tail -n 30 "$log" >&2
    echo "Failed: $* (log: $log)" >&2
    exit 1
  fi
}

step "NomadFS $version -> $out"

step "Command line node"
run cli-x86_64 zig build -Doptimize=ReleaseSafe -p "$out/build/x86_64"
cp "$out/build/x86_64/bin/nomadfs" "$assets/nomadfs-$version-x86_64-linux"
run cli-aarch64 zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -p "$out/build/aarch64"
cp "$out/build/aarch64/bin/nomadfs" "$assets/nomadfs-$version-aarch64-linux"

step "Desktop app (AppImage, deb, rpm)"
cd "$root/nomadfs-gui"
rm -rf zig-out/package
run gui-package zig build package -Doptimize=ReleaseSafe
cp zig-out/package/* "$assets/"

step "Android app"
run android-aarch64 zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-android
run android-x86_64 zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-android
(cd android && run gradle ./gradlew assembleDebug)
cp android/app/build/outputs/apk/debug/app-debug.apk "$assets/nomadfs-$version.apk"

step "Update manifest (latest.json)"
sign() { # <asset> <target> <format>
  run "sign-$2" zig build sign-update -- "$assets/$1" --app-id net.nomadfs.app \
    --version "$version" --target "$2" --format "$3" --url "$base/$1" \
    --key "$key" --out "$out/manifests/update-$2.json"
}
sign "nomadfs-gui-$version-x86_64.AppImage" x86_64-linux appimage
# One APK for both ABIs. The app opens its download; Android installs it.
sign "nomadfs-$version.apk" aarch64-android raw
sign "nomadfs-$version.apk" x86_64-android raw
run combine zig build combine-manifests -- "$out"/manifests/update-*.json \
  --pub-date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --out "$assets/latest.json"

cd "$assets"
sha256sum -- * > SHA256SUMS
step "Done"
ls -l "$assets"
cat <<EOF

Publish (after pushing main):
  git tag -a v$version -m "NomadFS $version" && git push origin v$version
  gh release create v$version $assets/* --title "NomadFS $version: ..." --notes-file <notes.md>
EOF
