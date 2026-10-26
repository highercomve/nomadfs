#!/usr/bin/env bash
# Builds the NomadFS C ABI library for Android with zig + the NDK's bionic
# libc. Zig cannot synthesize an Android libc by itself, so we hand it a
# libc definition file pointing at the NDK sysroot (see the zig libc file
# format documented at ziglang.org).
#
# Usage:
#   ./android-libc.sh [zig build args...]
#   NOMADFS_ANDROID_ABI=x86_64 ./android-libc.sh lib -p zig-out/abi/x86_64
#
# NOMADFS_ANDROID_ABI selects the packaged ABI:
#   arm64-v8a  -> aarch64-linux-android   (phones, tablets, Chromebooks)
#   x86_64     -> x86_64-linux-android    (emulators, ARC VM, Play Games)
#   x86        -> i686... (ARC++ images, mostly legacy)
#
# Requires: ANDROID_NDK_HOME and zig on PATH. Default output is
# zig-out/lib/libnomadfs.so; pass `lib -p <dir>` for per-ABI trees.

set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root

case "${NOMADFS_ANDROID_ABI:-arm64-v8a}" in
arm64-v8a) ZIG_TARGET="aarch64-linux-android" ;;
x86_64) ZIG_TARGET="x86_64-linux-android" ;;
x86) ZIG_TARGET="x86-linux-android" ;;
armeabi-v7a) ZIG_TARGET="arm-linux-androideabi" ;;
*) echo "unknown NOMADFS_ANDROID_ABI: $NOMADFS_ANDROID_ABI" >&2; exit 1 ;;
esac

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    latest="$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "$latest" ]] || { echo "ANDROID_NDK_HOME not set and no NDK under ~/Android/Sdk/ndk" >&2; exit 1; }
    export ANDROID_NDK_HOME="$latest"
fi
TC="$(cd "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" && pwd)"
[[ -d "$TC" ]] || { echo "NDK prebuilt toolchain not found under $ANDROID_NDK_HOME" >&2; exit 1; }

API="${ANDROID_API:-29}"
libc_file="/tmp/nomadfs-android-libc-${NOMADFS_ANDROID_ABI:-arm64-v8a}-${API}.txt"
cat >"$libc_file" <<EOF
include_dir=$TC/sysroot/usr/include
sys_include_dir=$TC/sysroot/usr/include/$ZIG_TARGET
crt1_dir=$TC/sysroot/usr/lib/$ZIG_TARGET/$API
crt_dir=$TC/sysroot/usr/lib/$ZIG_TARGET/$API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=$TC/lib
EOF

ZIG_LIBC="$libc_file" zig build -Dtarget="$ZIG_TARGET" "$@"
echo "Built $(pwd) for Android API $API ($ZIG_TARGET)."
