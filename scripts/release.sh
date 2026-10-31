#!/usr/bin/env bash
# Builds every asset of a NomadFS release and the signed update manifest
# the apps check (latest.json), for the version in nomadfs-gui/build.zig:
#
#   nomadfs-<v>-x86_64-linux, nomadfs-<v>-aarch64-linux   command line node
#   nomadfs-<v>-x86_64-windows.exe                         command line node (Windows)
#   nomadfs-gui-<v>-windows-x86_64-setup.exe               desktop app (Windows)
#   nomadfs-gui-<v>-x86_64-windows-update.exe              its self-update payload
#   (macOS: .github/workflows/desktop.yml builds the app and command line on
#   a Mac once the release is published, attaches them and adds their signed
#   entries to latest.json and latest-cli.json)
#   nomadfs-gui-<v>-x86_64.AppImage, .deb, .rpm            desktop app
#   nomadfs-<v>.apk                                        Android
#   latest.json                                            signed update manifest (the apps)
#   latest-cli.json                                        signed update manifest (nomadfs --upgrade)
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
# What a device reports about itself (GET_NODE_INFO).
grep -q "^pub const version = \"$version\";" src/node_info.zig || { echo "src/node_info.zig isn't at $version" >&2; exit 1; }
# The APK's version: written by `oriel android init` once, so bumped by
# hand. versionCode = MAJOR*10000 + MINOR*100 + PATCH (Oriel's rule).
IFS=. read -r major minor patch <<<"${version%%[-+]*}"
code=$((major * 10000 + minor * 100 + patch))
gradle=nomadfs-gui/android/app/build.gradle.kts
grep -q "versionName = \"$version\"" "$gradle" && grep -q "versionCode = $code\$" "$gradle" ||
  { echo "$gradle needs versionName = \"$version\" and versionCode = $code" >&2; exit 1; }

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

# x86_64 builds target the baseline CPU: without -Dcpu, Zig optimizes for
# this machine (AVX-512 here), and the binaries die with SIGILL on CPUs
# without it (a DigitalOcean droplet, older laptops).
x86_cpu=(-Dcpu=baseline)

step "Command line node"
run cli-x86_64 zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl "${x86_cpu[@]}" -p "$out/build/x86_64"
cp "$out/build/x86_64/bin/nomadfs" "$assets/nomadfs-$version-x86_64-linux"
run cli-aarch64 zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -p "$out/build/aarch64"
cp "$out/build/aarch64/bin/nomadfs" "$assets/nomadfs-$version-aarch64-linux"
run cli-windows zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu "${x86_cpu[@]}" -p "$out/build/windows"
cp "$out/build/windows/bin/nomadfs.exe" "$assets/nomadfs-$version-x86_64-windows.exe"

step "Desktop app (AppImage, deb, rpm)"
cd "$root/nomadfs-gui"
rm -rf zig-out/package
run gui-package zig build package -Doptimize=ReleaseSafe "${x86_cpu[@]}"
cp zig-out/package/* "$assets/"

step "Desktop app (Windows installer)"
# The WebView2 loader ships next to the app (`oriel webview2` caches it).
loader=$(ls -d "$HOME"/.oriel/webview2/*/x64/WebView2Loader.dll 2>/dev/null | sort -V | tail -1)
[ -n "$loader" ] || { echo "No WebView2Loader.dll: run 'oriel webview2'" >&2; exit 1; }
run gui-windows-exe zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu "${x86_cpu[@]}" -p "$out/build/gui-windows"
run gui-windows zig build package -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu "${x86_cpu[@]}" \
  -Dwebview2-loader="$loader" -p "$out/build/gui-windows"
cp "$out/build/gui-windows/package/nomadfs-gui-$version-setup.exe" "$assets/nomadfs-gui-$version-windows-x86_64-setup.exe"
# What an installed app downloads to update itself: the executable alone.
cp "$out/build/gui-windows/bin/nomadfs-gui.exe" "$assets/nomadfs-gui-$version-x86_64-windows-update.exe"

step "Android app"
run android-aarch64 zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-android
run android-x86_64 zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-android "${x86_cpu[@]}"
(cd android && run gradle ./gradlew assembleDebug)
cp android/app/build/outputs/apk/debug/app-debug.apk "$assets/nomadfs-$version.apk"

step "Update manifest (latest.json)"
sign() { # <asset> <target> <format> [<app id suffix> <manifest dir>]
  run "sign-$2${4:-}" zig build sign-update -- "$assets/$1" --app-id "com.foreachdeveloper.nomadfs${4:-}" \
    --version "$version" --target "$2" --format "$3" --url "$base/$1" \
    --key "$key" --out "$out/${5:-manifests}/update-$2.json"
}
sign "nomadfs-gui-$version-x86_64.AppImage" x86_64-linux appimage
sign "nomadfs-gui-$version-x86_64-windows-update.exe" x86_64-windows raw
# One APK for both ABIs. The app opens its download; Android installs it.
sign "nomadfs-$version.apk" aarch64-android raw
sign "nomadfs-$version.apk" x86_64-android raw
run combine zig build combine-manifests -- "$out"/manifests/update-*.json \
  --pub-date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --out "$assets/latest.json"
# The command line node: its own app id, so the app's manifest can't
# replace it with an AppImage (both are x86_64-linux).
mkdir -p "$out/manifests-cli"
sign "nomadfs-$version-x86_64-linux" x86_64-linux raw .cli manifests-cli
sign "nomadfs-$version-aarch64-linux" aarch64-linux raw .cli manifests-cli
sign "nomadfs-$version-x86_64-windows.exe" x86_64-windows raw .cli manifests-cli
run combine-cli zig build combine-manifests -- "$out"/manifests-cli/update-*.json \
  --pub-date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --out "$assets/latest-cli.json"

cd "$assets"
sha256sum -- * > SHA256SUMS
step "Done"
ls -l "$assets"
cat <<EOF

Publish (after pushing main):
  git tag -a v$version -m "NomadFS $version" && git push origin v$version
  gh release create v$version $assets/* --title "NomadFS $version: ..." --notes-file <notes.md>
EOF
