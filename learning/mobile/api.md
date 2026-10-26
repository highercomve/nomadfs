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

## 4. JNI Sketch

```c
JNIEXPORT jstring JNICALL
Java_net_nomadfs_NomadFs_putFile(JNIEnv *env, jobject self, jstring path) {
    const char *path_c = (*env)->GetStringUTFChars(env, path, NULL);
    char *cid = nomadfs_put_file(g_node, path_c);
    (*env)->ReleaseStringUTFChars(env, path, path_c);
    if (!cid) return NULL;
    jstring result = (*env)->NewStringUTF(env, cid);
    nomadfs_free(cid);
    return result;
}
```

Own `g_node` for the activity's lifetime (`node_new` in `onCreate`,
`node_free` in `onDestroy`); the listener and bootstrap threads are joined
by the same calls, so no native threads outlive the object.

---

**Next Chapters:**
* [Chapter 7.2: Swift Bindings](#) (planned)
* [Back to Internals](../README.md)
