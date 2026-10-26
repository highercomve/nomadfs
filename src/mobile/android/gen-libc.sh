#!/usr/bin/env bash
# Builds the NomadFS C ABI library for Android with zig + the NDK's bionic
# libc. Zig cannot synthesize an Android libc by itself, so we hand it a
# libc definition file pointing at the NDK sysroot (see zig-zig libc file
# format documented at ziglang.org).
#
# Usage:
#   ANDROID_API=29 ./android/gen-libc.sh <zig build args...>
#   e.g. ANDROID_API=29 ./android/gen-libc.sh -Doptimize=ReleaseSafe
#
# Requires: ANDROID_NDK_HOME (defaults to the newest NDK under
# ~/Android/Sdk/ndk) and zig on PATH. Emits zig-out/lib/libnomadfs.so.

set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    latest="$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "$latest" ]] || { echo "ANDROID_NDK_HOME not set and no NDK under ~/Android/Sdk/ndk" >&2; exit 1; }
    export ANDROID_NDK_HOME="$latest"
fi

TC="$(cd "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" && pwd)"
[[ -d "$TC" ]] || { echo "NDK prebuilt toolchain not found under $ANDROID_NDK_HOME" >&2; exit 1; }

API="${ANDROID_API:-29}"
libc_file="/tmp/nomadfs-android-libc-${API}.txt"
cat >"$libc_file" <<EOF
include_dir=$TC/sysroot/usr/include
sys_include_dir=$TC/sysroot/usr/include/aarch64-linux-android
crt1_dir=$TC/sysroot/usr/lib/aarch64-linux-android/$API
crt_dir=$TC/sysroot/usr/lib/aarch64-linux-android/$API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=$TC/lib
EOF

ZIG_LIBC="$libc_file" zig build -Dtarget="aarch64-linux-android" "$@"
echo "Built $(pwd)/zig-out/lib/libnomadfs.so for Android API $API."
