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
    src/mobile/android/emulator/src/net/nomadfs/harness/HarnessActivity.java \
    src/mobile/android/emulator/src/net/nomadfs/harness/RemoteNodeActivity.java

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
# Reuse a running emulator if one exists. A phone may be attached too, so
# every ADB command targets the emulator by serial.
EMU_SERIAL="$( $ADB devices | awk '/^emulator-.*\tdevice$/ {print $1; exit}' )"
if [[ -z "$EMU_SERIAL" ]]; then
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
while [[ -z "$EMU_SERIAL" ]]; do
    EMU_SERIAL="$( $ADB devices | awk '/^emulator-.*\tdevice$/ {print $1; exit}' )"
    sleep 1
done
"$ADB" -s "$EMU_SERIAL" wait-for-device
while [[ "$("$ADB" -s "$EMU_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" != "1" ]]; do
    sleep 2
done

echo "==> install"
"$ADB" -s "$EMU_SERIAL" install -r harness.apk >/dev/null

echo "==> run the binding harness on-device"
"$ADB" -s "$EMU_SERIAL" shell am start -W -n net.nomadfs.harness/net.nomadfs.harness.HarnessActivity | tee activity.log
for _ in $(seq 1 60); do
    if "$ADB" -s "$EMU_SERIAL" shell "logcat -d | grep -c 'NOMADFS-HARNESS'" | grep -q '[1-9]'; then break; fi
    sleep 2
done
"$ADB" -s "$EMU_SERIAL" shell "logcat -d" | grep "NOMADFS-HARNESS" | tail -3 | tee instrument.log
grep -q "NOMADFS-HARNESS: PASS" instrument.log
echo "HARNESS PASSED ON EMULATOR"

if [[ "$KEEP" != "--keep" ]]; then
    "$ADB" -s "$EMU_SERIAL" uninstall net.nomadfs.harness >/dev/null || true
fi

cross_device() {
    # Cross-device transfer: emulator (x86_64, ARC ABI) x real phone
    # (arm64-v8a). Payload is deterministic, so both ends regenerate and
    # byte-compare on-device. Requires both devices attached.
    set -u
    EMU="${EMU_SERIAL:-$( $ADB devices | awk '/^emulator-.*\tdevice$/ {print $1; exit}' )}"
    PHONE="${PHONE_SERIAL:-$( $ADB devices | awk '$2=="device" && $1 !~ /^emulator-/ {print $1; exit}' )}"
    LEN="${PAYLOAD_LEN:-2000000}"
    "$ADB" -s "$EMU" shell am force-stop net.nomadfs.harness 2>/dev/null || true
    "$ADB" -s "$PHONE" shell am force-stop net.nomadfs.harness 2>/dev/null || true

    echo "==> emulator node (serve)"
    "$ADB" -s "$EMU" shell am start -W \
        -e mode serve -e port 13500 \
        -n net.nomadfs.harness/.RemoteNodeActivity | tail -1
    echo "==> phone reverse tunnel to the emulator"
    "$ADB" -s "$PHONE" reverse --remove-all >/dev/null 2>&1 || true
    "$ADB" -s "$PHONE" reverse tcp:13500 tcp:13500

    echo "==> phone node (put)"
    "$ADB" -s "$PHONE" shell am start -W \
        -e mode put -e port 13500 -e peer tcp://127.0.0.1:13500 \
        -e payloadLen $LEN \
        -n net.nomadfs.harness/.RemoteNodeActivity | tail -1
    CID=""
    for _ in $(seq 1 60); do
        L="$("$ADB" -s "$PHONE" shell logcat -d | grep 'NOMADFS-REMOTE CID' | tail -1 | sed 's/.*CID: //')"
        [[ -n "$L" ]] && CID="$L" && break
        sleep 2
    done
    [[ -n "$CID" ]] || { echo "cross-device: no CID" >&2; exit 1; }
    echo "cid=$CID"

    echo "==> emulator node (get from the phone)"
    "$ADB" -s "$EMU" shell am start -W \
        -e mode get -e port 13500 -e peer tcp://127.0.0.1:13500 \
        -e cid "$CID" -e payloadLen $LEN \
        -n net.nomadfs.harness/.RemoteNodeActivity | tail -1
    for _ in $(seq 1 30); do
        if "$ADB" -s "$EMU" shell logcat -d | grep -c "NOMADFS-REMOTE: DONE" | grep -qv 0; then break; fi
        sleep 2
    done
    LINE="$("$ADB" -s "$EMU" shell logcat -d | grep 'NOMADFS-REMOTE: DONE' | tail -1)"
    echo "$LINE"
    echo "$LINE" | grep -qv "status=0" && { echo "cross-device: FAILED - $LINE" >&2; exit 1; }
    "$ADB" -s "$EMU" shell am force-stop net.nomadfs.harness
    "$ADB" -s "$PHONE" shell am force-stop net.nomadfs.harness
    "$ADB" -s "$PHONE" reverse --remove-all >/dev/null 2>&1 || true
    echo "CROSS-DEVICE PASS (emulator x86_64 fetched ${LEN} bytes from the arm64 phone through the C ABI)"
    
}

[[ "${1:-}" == "cross-device" ]] && { cross_device; exit $?; }
