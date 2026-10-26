#!/usr/bin/env bash
# Runs the NomadFS JNI binding on a real Android emulator (ART), assembling
# the harness APK by hand from the SDK build tools (no Gradle needed).
#
#   ./src/mobile/android/emulator/harness.sh [--keep]
#
# Steps: cross-build the zig C ABI library with the NDK, ndk-build the JNI
# bridge, create/boot a headless AVD if none is running, package the APK
# with aapt2+d8+apksigner, adb install it, and run the instrumentation.
# Prints NOMADFS-HARNESS: PASS on success.

set -euo pipefail
cd "$(dirname "$0")/../../../.." # repo root

SDK="${ANDROID_SDK_HOME:-$HOME/Android/Sdk}"
TOOLS="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-35/android.jar"
ADB="$SDK/platform-tools/adb"
AVD_NAME="${NOMADFS_AVD:-nomadfs_ci}"
API="${ANDROID_API:-29}"
OUT="/tmp/nomadfs-emulator"
KEEP="${1:-}"

mkdir -p "$OUT/build/obj" "$OUT/build/dex"
rm -rf "$OUT/build/obj"/* "$OUT/build/dex"/* "$OUT/build/harness.apk" \
    "$OUT/build/unsigned.apk" "$OUT/build/aligned.apk" 2>/dev/null || true

echo "==> zig build the Android C ABI library (Chromebook/Googlebook: arm64 + x86_64)"
rm -rf zig-out/android
for ABI in arm64-v8a x86_64; do
    NOMADFS_ANDROID_ABI="$ABI" ./src/mobile/android/gen-libc.sh lib -p "zig-out/android/$ABI" >/dev/null
done

echo "==> ndk-build the JNI bridge (both ABIs)"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Android/Sdk/ndk/* | sort -V | tail -1)}"
PATH="$ANDROID_NDK_HOME:$PATH" ndk-build -C src/mobile/android >/dev/null

echo "==> compile Java against the platform"
javac --release 17 -classpath "$PLATFORM" -d "$OUT/build/obj" \
    src/mobile/android/java/net/nomadfs/NomadFs.java \
    src/mobile/android/emulator/src/net/nomadfs/harness/NomadFsInstrumentation.java \
    src/mobile/android/emulator/src/net/nomadfs/harness/HarnessActivity.java

echo "==> dex"
"$TOOLS/d8" --release --min-api "$API" --lib "$PLATFORM" \
    --output "$OUT/build/dex" $(find "$OUT/build/obj" -name '*.class') >/dev/null

echo "==> package APK"
SRC="$PWD"
cd "$OUT/build"
"$TOOLS/aapt2" link \
    -I "$PLATFORM" \
    --manifest "$SRC/src/mobile/android/emulator/AndroidManifest.xml" \
    --min-sdk-version "$API" --target-sdk-version 35 \
    -o unsigned.apk
cp dex/classes.dex classes.dex
zip -q unsigned.apk classes.dex
# jniLibs: both ABIs. The device picks its own at install time, so the
# same APK runs on your arm64 Chromebook and this x86_64 emulator (ARC VM).
mkdir -p lib/arm64-v8a lib/x86_64
for ABI in arm64-v8a x86_64; do
    cp "$SRC/zig-out/android/$ABI/lib-android/libnomadfs.so" "lib/$ABI/"
    cp "$SRC/src/mobile/android/libs/$ABI/libnomadfs_jni.so" "lib/$ABI/"
    [[ -f "$OUT/build/wrap/wrap.sh" ]] && cp "$OUT/build/wrap/wrap.sh" "lib/$ABI/" || true
done
zip -qr unsigned.apk lib

echo "==> sign"
[[ -f debug.keystore ]] || keytool -genkeypair -keystore debug.keystore \
    -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug,O=NomadFS,C=US" -keyalg RSA -keysize 2048 \
    -validity 10000 >/dev/null 2>&1
"$TOOLS/zipalign" -f 4 unsigned.apk aligned.apk
"$TOOLS/apksigner" sign --ks debug.keystore --ks-pass pass:android \
    --key-pass pass:android --ks-key-alias androiddebugkey \
    --out harness.apk aligned.apk

echo "==> boot emulator (KVM)"
# Reuse a running emulator if one exists.
if ! "$ADB" get-state >/dev/null 2>&1; then
    CLI="$SDK/cmdline-tools/latest/bin"
    "$CLI/avdmanager" list avd 2>/dev/null | grep -q "Name: $AVD_NAME" || \
        echo no | "$CLI/avdmanager" create avd \
        -n "$AVD_NAME" -k "system-images;android-35;google_apis;x86_64" \
        -d pixel_5 >/dev/null
    "$SDK/emulator/emulator" -avd "$AVD_NAME" -no-window -no-audio \
        -no-boot-anim -gpu swiftshader_indirect -no-snapshot >/dev/null 2>&1 &
    EMU_PID=$!
    trap 'kill "$EMU_PID" 2>/dev/null || true' EXIT
fi
until "$ADB" get-state >/dev/null 2>&1; do sleep 1; done
"$ADB" wait-for-device
while [[ "$("$ADB" shell getprop sys.boot_completed | tr -d '\r')" != "1" ]]; do
    sleep 2
done

echo "==> install"
"$ADB" install -r harness.apk >/dev/null

echo "==> run the binding harness on-device"
"$ADB" shell am start -W -n net.nomadfs.harness/net.nomadfs.harness.HarnessActivity | tee activity.log
for _ in $(seq 1 60); do
    if "$ADB" shell "logcat -d | grep -c 'NOMADFS-HARNESS'" | grep -q '[1-9]'; then break; fi
    sleep 2
done
"$ADB" shell "logcat -d" | grep "NOMADFS-HARNESS" | tail -3 | tee instrument.log
grep -q "NOMADFS-HARNESS: PASS" instrument.log
echo "HARNESS PASSED ON EMULATOR"

if [[ "$KEEP" != "--keep" ]]; then
    "$ADB" uninstall net.nomadfs.harness >/dev/null || true
fi
