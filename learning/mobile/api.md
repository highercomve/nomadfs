# Chapter 7.1: The Mobile C ABI

Mobile hosts (Android via JNI, Apple platforms via Swift, or any FFI
language) talk to NomadFS through a small exported C surface in
`src/mobile/api.zig`. The same code is the CLI's `nomadfs` binary, so
behaviour is identical - the bindings only wrap lifecycle, storage I/O and
pins.

## 1. Surface

Declared in `src/mobile/nomadfs.h` (committed, use it for FFI codegen):

| Symbol | Purpose |
| :--- | :--- |
| `nomadfs_version` | Human-readable library version |
| `nomadfs_node_new` | Loads config, storage, device identity, trust store |
| `nomadfs_node_run` / `nomadfs_node_stop` | Start/stop the TCP listener (own thread) |
| `nomadfs_node_bootstrap` | Dial comma-separated bootstrap peers |
| `nomadfs_put_file` | Chunk + store + announce, returns 64-hex root CID |
| `nomadfs_get_file` | Reassemble by CID (holder records, then closest peers) |
| `nomadfs_node_device_id` | Node's device ID as 64 hex characters |
| `nomadfs_free` | Release returned CIDs |

Contract rules:

- statuses are `c_int`, `0` is ok, unknown failures collapse to
  `NOMADFS_INTERNAL_ERROR` (9); Zig panics never cross the boundary;
- calls on one handle are serialized internally (a mutex protects the
  Node), so background reads are safe from any host thread;
- strings in are borrowed; strings out are NUL-terminated allocations freed
  with `nomadfs_free`;
- `nomadfs_put_file` reports NULL when the provider-record quorum missed -
  blocks remain local and a retry after connecting announces them.

## 2. Life Cycle (C)

```c
NomadNode *node = nomadfs_node_new("/data/nomadfs.conf");
nomadfs_node_run(node);                                   // listener thread
nomadfs_node_bootstrap(node, "tcp://192.168.1.5:9000");   // join the swarm
char *cid = nomadfs_put_file(node, "/sdcard/backup.zip");
int rc = nomadfs_get_file(node, cid, "/data/restore.zip");
nomadfs_free(cid);
nomadfs_node_free(node);                                  // stops listener
```

Config files, directory layout and pairing behave exactly like the desktop
CSS CLI (`--pair`, `--trust`, `--devices`, `--revoke`), so a phone and a
laptop pair through the same QR ticket flow.

## 3. Building the Library

| Host | Command | Result |
| :--- | :--- | :--- |
| Linux (this machine) | `zig build` | `zig-out/lib/libnomadfs.so` |
| Mac (any arch) | `zig build -Dtarget=aarch64-macos` | `libnomadfs.dylib` |
| Windows | `zig build -Dtarget=x86_64-windows-gnu` | `nomadfs.dll` (via `nomadfs.lib`) |
| Android (per ABI) | `gen-libc.sh lib -p zig-out/android/<abi>` | `zig-out/android/<abi>/lib-android/` |

### Android

Two supported paths:

1. **NDK (preferred, bionic libc):** run inside the Android NDK environment
   and pass a libc definition file so Zig can use bionic:

   ```sh
   zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe \
     -Dlibc-file=android/aarch64-linux-android-29.txt
   ```

   (Create the libc file with the NDK's sysroot as documented in the Zig
   libc hunting guide; api-aware version 29 matches modern devices.)

2. **musl (no NDK required):** the fallback ships a statically linked libc
   and has been verified in this repo:

   ```sh
   zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
   ```

   It runs on devices but does not use bionic; keep it for Lab-scope tests
   or hosts where the NDK is not available.

## 4. Android JNI (committed sources)

`src/mobile/android/` holds everything the app module needs:

| Path | Contents |
| :--- | :--- |
| `jni/NomadFsJNI.c` | JNI bridge; one function per Java method, handle as `jlong` |
| `jni/Android.mk`, `jni/Application.mk` | `ndk-build` recipe; links against the zig-built `libnomadfs.so` |
| `java/net/nomadfs/NomadFs.java` | `AutoCloseable` binding: `open`, `run`, `stop`, `bootstrap`, `put`, `get`, `deviceId`, `close` |
| `gen-libc.sh` | Writes the NDK-bionic libc definition zig needs for `-Dtarget=aarch64-linux-android`, then builds |

Verified pipeline (run from the repo root once `ANDROID_NDK_HOME` is set):

```sh
./src/mobile/android/gen-libc.sh          # -> zig-out/lib/libnomadfs.so (API 29, arm64)
ndk-build -C src/mobile/android           # -> src/mobile/android/libs/arm64-v8a/libnomadfs_jni.so
javac -d out src/mobile/android/java/net/nomadfs/NomadFs.java
```

Drop `zig-out/lib/libnomadfs.so` and `libs/arm64-v8a/libnomadfs_jni.so`
into your app's `jniLibs/arm64-v8a/` and own one `NomadFs` instance for the
activity's lifetime (`open` in `onCreate`, `close` in `onDestroy`); the
listener and bootstrap threads are joined by the same calls, so no native
threads outlive the object.

## 4b. Gradle (library module)

`src/mobile/android/library/` is a self-contained Android library module
that produces the artifact an app consumes:

```
settings.gradle + build.gradle
java/...        (via sourceSets: the same binding class as the CLI uses)
local.properties (sdk.dir; gitignored, one line: sdk.dir=<Android Sdk>)
```

It drives the whole pipeline itself:

1. per-ABI `zig build lib` into `zig-out/android/<abi>` (`NOMADFS_ANDROID_ABI`),
2. one `ndk-build` pass for the JNI bridge over both ABIs,
3. `stageJni` copies the `.so` set into `build/staged/libs/<abi>/`,
4. AGP packages `classes.jar + jni/{arm64-v8a,x86_64}/{libnomadfs,libnomadfs_jni}.so`
   into `build/outputs/aar/nomadfs-android-debug.aar`.

Run it with any Gradle between 8.10 and 9.5 (AGP 8.13 compatibility):

```sh
gradle -p src/mobile/android/library assembleDebug
```

The AAR is consumable like any Android library:

```gradle
dependencies {
    implementation(files("path/to/nomadfs-android-debug.aar"))
}
```

and then the same `net.nomadfs.NomadFs` API, with Gradle doing the
`Packaged`→`CODE` packaging for phones, emulators, and Googlebook
classpath arrays alike (both ABIs live inside one AAR; the OS picks its
own).

## 5. Chromebooks & Googlebook

Googlebook devices run Android apps through the ChromeOS Android runtime
(ARC VM), and so do their Chromebook predecessors. Two things matter for
NomadFS:

1. **ABI coverage.** ARC hosts are `x86_64` (Intel Core Ultra) or
   `arm64-v8a` (Snapdragon X Elite). The repo therefore builds both ABIs
   (`gen-libc.sh` honors `NOMADFS_ANDROID_ABI=` and `Android.mk` links a
   per-ABI prebuilt), and the harness APK packages them into both
   `lib/x86_64` and `lib/arm64-v8a` so one APK installs anywhere. Desktop
   mode and Googlebook windowing do not change the ABI: a headless binding
   sees the same sandbox, storage paths and ` INTERNET` permission.

2. **Bionic seccomp.** Android (including ARC VM) blocks the raw `poll`
   syscall; the connect-timeout code waits via `ppoll`, which matches what
   bionic uses everywhere. This is verified on-device (see below).

## 6. On-device harness (emulator verdict)

`src/mobile/android/emulator/harness.sh` assembles a debug APK from the
SDK build tools (aapt2 + d8 + apksigner, no Gradle), boots or reuses a
headless AVD (KVM), installs it, and runs a real end-to-end flow inside
ART's app namespace through the Java binding:

- two nodes with distinct device ids open, run and stop cleanly;
- B bootstraps against A, then a 200 KB payload passes B -> A (A fetches
  every missing block from B, verifying each CID), byte-identical;

Verified outcomes so far:

- `api-35 x86_64` AVD: `NOMADFS-HARNESS: PASS` (ARC VM/Googlebook ABI).
- A real arm64 phone (Android 12 / MIUI): `NOMADFS-HARNESS: PASS` after
  MIUI's "Install via USB" switch was enabled.
- **Cross-architecture**: a 2 MB transfer where the phone (arm64) filled its
  local DAG and a host (x86_64, `src/mobile/testing/host-probe.c`) fetched
  the file over the LAN and byte-compared it. arm64 server serving x86_64
  client through the same C ABI, plus both sides hitting the `ppoll`
  seccomp profile.

`./harness.sh cross-device` automates the emulator x phone transfer (needs
both devices; adb reverse/forward picks up whatever is attached). Standalone
single-device puts use `write_quorum = 0` (a config knob: a device with no
peers can still store locally and announce its content).

## 7. Swift (committed sources)

`src/mobile/swift/` is a SwiftPM package rooted at `src/mobile` that wraps
the same header:

- `Sources/CNomadFs/` - header-only C target (shim, module map
  generated by SwiftPM) linking `libnomadfs.so` from `zig-out/lib`;
- `Sources/NomadFs/NomadFs.swift` - the same `open/run/stop/bootstrap/
  put/get/deviceId/close` surface, with `deinit` releasing the handle;
- `Tests/NomadFsTests/` - a two-node put/get round trip running the real
  library in-process.

Verified locally (Swift 6.4 on Linux):

```sh
zig build                     # native lib at ../../zig-out/lib
cd src/mobile && swift test   # full round trip through the ABI
```

App-side usage follows the same lifecycle as the C example above. One Swift
specific to note: build device IDs from `[UInt8]` with
`String(decoding:as:)`; `String(cString:)` over the bridged array crashes
inside `swift_retain` on this toolchain.

---

**Next Chapters:**
* [Chapter 7.2: Swift Bindings](#) (planned)
* [Back to Internals](../README.md)
