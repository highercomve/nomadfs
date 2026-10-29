# Chapter 10: The Mobile C ABI & Bindings

NomadFS reaches non-Zig hosts through a small C ABI: `src/mobile/api.zig`
exports it, `src/mobile/nomadfs.h` declares it, and `zig build` (or
`zig build lib`) produces `libnomadfs.so` / `.dylib` / `nomadfs.dll`. On top
of it sit a JNI bridge and Java class for Android
(`src/mobile/android/`) and a SwiftPM package (`src/mobile/`).

**This is not how the NomadFS app works.** The app (`nomadfs-gui`, built
with Oriel; see [Chapter 7](../app/gui.md)) imports the NomadFS Zig module
directly and calls these same functions in-process (`mobile.nomadfs_node_new`
and friends in `nomadfs-gui/src/commands.zig`), next to the rest of the Zig
API: shares, the swarm folder, pairing, invites, rotation. The C ABI is
the narrower surface for other hosts.

## 1. Surface

Everything `nomadfs.h` declares (all are `export fn` in `api.zig`):

| Symbol | Purpose |
| :--- | :--- |
| `nomadfs_version` | Library version string |
| `nomadfs_node_new(config_path)` | Parse the config and `Node.init`: storage, shares, swarm folder, device identity, trust store. `NULL` on a bad or missing config |
| `nomadfs_node_free` | Stop listener and manager threads, safe teardown serialized against concurrent calls, free everything |
| `nomadfs_node_run` | Binds listener synchronously before returning `NOMADFS_OK`. Idempotent no-op while running. Returns `NOMADFS_UNAVAILABLE` on bind failure or if called after stop |
| `nomadfs_node_stop` | Stop listener and join threads. Cannot be re-run; allocate a new node to restart |
| `nomadfs_node_bootstrap(node, urls_csv)` | `Node.bootstrap` with comma-separated `tcp://host:port` peers |
| `nomadfs_put_file(node, in_path)` | `BlockManager.put`: chunk, store, announce; returns a 64-hex root CID. Nothing is pushed: other devices fetch it when they read it |
| `nomadfs_get_file(node, cid, out_path)` | `BlockManager.get`: strictly validates 64-hex CID before creating `out_path`, enforces 4 GiB download limit, fetches missing blocks |
| `nomadfs_node_device_id(node, out, out_len)` | Device ID as 64 hex characters + NUL |
| `nomadfs_free` | Release a CID string from `nomadfs_put_file` |

Status codes: `NOMADFS_OK` 0, `INVALID_ARGUMENT` 1, `STORAGE_DISABLED` 2,
`UNAVAILABLE` 3, `FILE_TOO_LARGE` 4, `NOT_FOUND` 5, `INTERNAL_ERROR` 9.

**Not exported**: pairing (`--pair`/`--trust`), the trust store, invites,
key rotation, revocation, shares, the swarm folder and the mount. A C host
gets a running node (which does serve its configured shares and sync its
swarm folder in the background) plus file put/get; device management goes
through the Zig API ([Chapter 9](../api/reference.md)) as the app does, or
through the CLI on desktops.

Contract rules:

- statuses are `c_int`, `0` is ok; unknown failures collapse to
  `NOMADFS_INTERNAL_ERROR`; Zig errors never cross the boundary;
- calls on one handle are serialized by a mutex and reference-counted handle
  tracking, so any host thread may call and safe teardown is guaranteed;
- `nomadfs_node_run` binds listeners synchronously, surfacing port bind or
  network startup failures immediately;
- once stopped with `nomadfs_node_stop`, a node handle transitions to stopped
  and cannot be restarted (further `run` calls return `NOMADFS_UNAVAILABLE`);
  create a new handle with `nomadfs_node_new` instead;
- `nomadfs_get_file` requires exactly 64 valid hexadecimal characters for the
  CID, returning `NOMADFS_INVALID_ARGUMENT` without creating or truncating the
  target file if invalid, and enforces a 4 GiB maximum file size limit;
- input strings are borrowed; the CID string returned by `nomadfs_put_file`
  is freed with `nomadfs_free`;
- `nomadfs_put_file` returns `NULL` when the provider-record quorum missed
  (e.g. offline with `write_quorum >= 1`) or on any other error. The blocks
  are stored locally either way; set `write_quorum = 0` on devices that must
  store while alone.

## 2. Life Cycle (C)

```c
NomadNode *node = nomadfs_node_new("/data/nomadfs.conf");
nomadfs_node_run(node);                                   // binds listener synchronously
nomadfs_node_bootstrap(node, "tcp://192.168.1.5:9000");   // join the swarm
char *cid = nomadfs_put_file(node, "/sdcard/backup.zip");
int rc = nomadfs_get_file(node, cid, "/data/restore.zip");
nomadfs_free(cid);
nomadfs_node_free(node);                                  // stops listener and frees
```

The config file and the key/trust-store locations are the same as for the
desktop CLI ([Chapter 8.2](../ops/configuration.md)).

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

## 6. On-device harness

`src/mobile/android/emulator/harness.sh` assembles a debug APK from the
SDK build tools (aapt2 + d8 + apksigner, no Gradle), boots or reuses a
headless AVD (KVM), installs it, and runs a real end-to-end flow inside
ART's app namespace through the Java binding:

- two nodes with distinct device ids open, run and stop cleanly;
- B bootstraps against A, then a 200 KB payload passes B -> A (A fetches
  every missing block from B, verifying each CID), byte-identical;

Outcomes recorded when the harness was written (not re-run for this
revision of the book):

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

The SwiftPM package lives directly in `src/mobile/` (`Package.swift`,
`Sources/`, `Tests/`) and wraps the same header:

- `Sources/CNomadFs/` - C target (`shim.c`, `include/nomadfs.h` symlinked to
  the real header) linking `libnomadfs` from `<repo>/zig-out/lib`;
- `Sources/NomadFs/NomadFs.swift` - the same `open/run/stop/bootstrap/
  put/get/deviceId/close` surface, with `deinit` releasing the handle;
- `Tests/NomadFsTests/` - a two-node put/get round trip running the real
  library in-process.

Recorded run (Swift 6.4 on Linux):

```sh
zig build                     # native lib at ../../zig-out/lib
cd src/mobile && swift test   # full round trip through the ABI
```

App-side usage follows the same lifecycle as the C example above. One Swift
specific to note: build device IDs from `[UInt8]` with
`String(decoding:as:)`; `String(cString:)` over the bridged array crashes
inside `swift_retain` on this toolchain.

---

**Next:** [Chapter 11: Testing](../testing.md) ·
[Back to the Internals Book](../README.md)
