# Chapter 5.3: The FUSE Mount (`src/fs/fuse.zig`)

On Linux, `nomadfs --mount <dir>` (or the desktop app's **Mount** tab and tray menu) shows every
reachable device's shares and the swarm folder as an ordinary directory:

```
<mount>/
├── <device>/<share>/…   read-only  (files 0444, folders 0555)
└── Swarm/…              writable   (files 0644, folders 0755)
```

The driver speaks the kernel's FUSE protocol directly on `/dev/fuse`. There is **no libfuse and no
libc**: the C structs from `include/uapi/linux/fuse.h` are declared as Zig `extern struct`s and the
syscalls go through `std.os.linux`. Concepts, with diagrams:
[FUSE, no libfuse](https://nomadfs.foreachdeveloper.com/learn/fuse/).

## 1. Mounting without root (`mountWithFusermount`)\n
Only root may call `mount(2)`, so FUSE ships the setuid helper `fusermount3` (package `fuse3`).
NomadFS drives it the way libfuse does:

1. `socketpair(AF_UNIX, SOCK_STREAM)`; one end is left inheritable.
2. Run `fusermount3 -o rw,nosuid,nodev,default_permissions,fsname=nomadfs,subtype=nomadfs -- <dir>`
   (looked up in `/usr/bin`, `/bin`, `/usr/local/bin`) with `_FUSE_COMMFD=<fd>` in its environment.
3. `fusermount3` opens `/dev/fuse`, mounts it, and sends the descriptor back as `SCM_RIGHTS`
   ancillary data; `recvmsg` extracts it.

`unmount(mountpoint)` runs `fusermount3 -u -z` (a lazy unmount: the kernel detaches the folder
once it is idle). The CLI does it on Ctrl-C or `SIGTERM`; unmounting makes the serve loop return,
which shuts the node down. The app also clears a stale NomadFS mount at the same folder before
mounting.

## 2. The serve loop & worker pool

`Mount.serve(mountpoint)` manages an on-demand pool of worker threads on `/dev/fuse` (up to `worker_max = 16`),
following the libfuse `fuse_loop_mt` design:

```
worker loop:
    idle.fetchAdd(1)
    n = read(/dev/fuse, req_buf)            // blocks waiting for next kernel request
    idle.fetchSub(1)
    if (idle == 0 and pool.count < 16) spawnWorker()
    dispatch(req_buf[0..n])                 // processes request, writes reply to /dev/fuse
```

- **Per-worker buffers:** Each worker thread reads into a 128 KiB request buffer on its stack. Dynamic replies
  use a growable `threadlocal` reply buffer (`tl_reply`) that grows to accommodate `max_write` (128 KiB)
  and directory listings without locking.
- **On-demand concurrency:** If all running workers are busy and a new request arrives, an additional worker
  thread is spawned on demand until the cap of 16 is reached.
- **Clean shutdown:** When unmounted (`ENODEV` or EOF on socket closing), `stopping` is signaled, and all
  workers exit their loop. The pool joins all spawned threads cleanly.
- **Opcode concurrency:**
  - Independent reads, lookups, getattrs, and directory traversals run concurrently across threads.
  - The mount lock (`Mount.lock`) is held only for brief in-memory table operations (inode lookup, handle maps)
    and is **never held across network dials, remote block fetches, chunking/hashing, or disk operations**.
  - Swarm file writes are protected by an atomic writer table (`Mount.writing`), allowing concurrent reads
    while refusing concurrent open-for-write on the same file with `EBUSY`.

`dispatch` switches on `InHeader.opcode`:

| Opcodes | Handler |
| :--- | :--- |
| `INIT` | `opInit`: negotiates protocol **7.31** (minor = min(kernel's, 31)); keeps only `FUSE_ATOMIC_O_TRUNC` and `FUSE_BIG_WRITES`; `max_write` 128 KiB |
| `LOOKUP`, `GETATTR`, `ACCESS`, `STATFS` | attributes and names |
| `OPENDIR`, `READDIR`, `RELEASEDIR` | listings |
| `OPEN`, `READ`, `RELEASE`, `FLUSH`, `FSYNC` | file reads (and swarm commits on `RELEASE`) |
| `CREATE`, `WRITE`, `SETATTR`, `MKDIR`, `UNLINK`, `RMDIR`, `RENAME`, `RENAME2` | swarm folder writes |
| `FORGET`, `BATCH_FORGET` | lower an inode's lookup count; no reply |
| `INTERRUPT` | ignored |
| `DESTROY` | reply and leave the loop |
| `GETXATTR`, `LISTXATTR`, anything else | `ENOSYS` |

Replies carry `entry_valid` / `attr_valid` = `cache_seconds` = **1 s**, so the kernel re-asks
soon and changes on other devices show up quickly.

## 3. The inode model & background device refresh

```zig
const Kind = enum { root, device, dir, file, swarm_dir, swarm_file };
```

- `inodes` is an `InodeTable` (`src/fs/inode_table.zig`) keyed by inode number. Numbers come from a counter
  and are **never reused** while mounted, so every reply can use generation 0.
- Each entry counts how many times the kernel has looked it up (`nlookup`): every successful
  `LOOKUP`, `CREATE` and `MKDIR` reply adds one, and `FORGET` / `BATCH_FORGET` subtract. `READDIR`
  replies add nothing (they carry directory-entry numbers only). When an entry's count is 0 and
  nothing below it or open on it remains, it is freed, so the table is as big as the kernel's own
  inode cache, not as big as everything ever listed.
- Each entry knows its parent and name; swarm paths are built by walking up, so renaming a folder
  is one change. A name is detached when its file is removed, renamed over, or gone from the
  listing: a later file of the same name gets a new inode number.
- Share inodes carry `device` (an index into `devices`) and `cid`; swarm inodes carry `author`
  (the device to fetch from first).
- **Background device refresh:** A dedicated background thread (`startRefresher`) maintains the device
  list with stale-while-revalidate behavior.
  - Known peers (`fs.remote.knownPeers`) are probed in parallel across up to `refresh_parallel = 8` worker
    threads without holding `Mount.lock`.
  - Discovered share listings are reconciled and applied atomically under `Mount.lock` to `Mount.devices`.
  - Stale cached device lists are served immediately; directory listings trigger an async refresh if
    the cache is older than 5 s (`device_refresh_ns`). The first root listing waits up to 3 s for the initial
    refresh.

### Device folder names

A device's folder under the mount root is chosen locally, never by the device:
- A **paired** device (one in this device's trust store) is named by its trust-store label. If two
  paired devices share a label, the one paired first keeps it and the other gets `-<fingerprint>`.
- Any other device is named `<its claimed nickname>-<first 8 hex digits of its device fingerprint>`
  (`device-…` if it claims none). The digits are the first two groups of the fingerprint the app
  and `nomadfs --devices` show, so you can compare them.
- The nickname a device sends in `SHARES` is not authenticated; the device identity behind the
  connection is. Names are recomputed whenever the device list is refreshed and do not depend on
  which device answered first. `Swarm` is reserved.

## 4. The read path

- **Listing** a share folder is `tree.listDir` over the device's `Remote` loader: one dir block.
- **Reading** a share file (`opRead` → `readFile`) is `tree.readAt` over the same loader. Only the
  blocks covering the requested range are loaded; fetched blocks are verified and stay in the
  local store ([Chapter 5.1](./shares.md)).
- **Reading** a swarm file is `SwarmFolder.readAt` (author first, then every known peer). If the
  file is open for writing, the read is served from its staging file instead.

## 5. The write path (only `Swarm/`)

A swarm file is a tree of hashed blocks, so it can't be changed in place. Writes are staged.

```zig
const Handle = struct {
    ino: u64,
    staging: [:0]u8,  // <storage_path>.swarm.json.staging/<fh>.part
    fd: i32,
    dirty: bool,
};
```

1. **`OPEN` with write access, or `CREATE`** → `openForWrite` / `newHandle` creates the staging
   file (mode 0600). Opening an existing file **without `O_TRUNC`** first copies its current
   content in through `SwarmFolder.readAt` (fetching blocks if needed), so appends and in-place
   edits work. Concurrent `openForWrite` on the same file is refused with `EBUSY`.
2. **`WRITE`** → `pwrite` into the staging file under local handle bounds; the inode's size and mtime are updated at once.
3. **`SETATTR` with a size** → `ftruncate` on the open handle; a truncate with no open file is
   staged, cut and committed immediately.
4. **`RELEASE`** (last close) → `commit`: if dirty, `SwarmFolder.addFile(dir, name, staging)`
   chunks the staged bytes into the block store and records **one** manifest edit outside `Mount.lock`.
   Other devices never see a half-written file. The staging file is removed. A file unlinked while open is
   dropped, not re-added, when it is closed.

Directory operations map onto the swarm API directly: `MKDIR` → `makeDir`; `UNLINK` → `remove`;
`RMDIR` → `remove`, refused with `ENOTEMPTY` while the folder has live entries; `RENAME` /
`RENAME2` → `move` (replacing the target unless `RENAME_NOREPLACE`), and a file still open for
writing is committed before it moves. That covers editors that save to a temporary file and rename
it over the original.

## 6. Errors

| Situation | errno |
| :--- | :--- |
| Writing, truncating or creating under a device share | `EROFS` |
| Renaming between `Swarm/` and a device share | `EXDEV` (a cross-filesystem move) |
| Concurrent open for write on a swarm file | `EBUSY` |
| `rmdir` on a non-empty swarm folder | `ENOTEMPTY` |
| Extended attributes | `ENOSYS` |
| Swarm errors (`errnoFor`) | `FileNotFound` → `ENOENT`, `PathAlreadyExists` → `EEXIST`, `InvalidPath` → `EINVAL`, `NameTooLong` → `ENAMETOOLONG`, `ReadOnly` → `EROFS`, other → `EIO` |
| A block no device can serve / down peer | `EIO` on that read |

## 7. Limits & Concurrency

- Linux only (`/dev/fuse`, `fusermount3`). The app's Mount tab is shown only where mounting works.
- Concurrent requests: up to 16 worker threads concurrently serve requests from `/dev/fuse`.
- Network resilience: slow network or remote hash verification on one file does not stall independent
  requests (such as `LOOKUP`, `GETATTR`, or `STATFS`).
- Per-peer health gate: dead or unresponsive peers back off exponentially (5 s to 60 s), failing fast
  with `EIO` (`error.PeerDown`) without stalling worker threads.
- No extended attributes, symlinks or hard links. Mode and time changes (`chmod`, `touch`,
  `cp -p`) are accepted but not stored; the modes shown are fixed.
- `d_ino` values in directory listings are not the inode numbers `stat` reports (like libfuse without `use_ino`).

Blocks read through the mount go to the store's read cache, which keeps the most recently read up
to `cache_mb` ([the read cache](../storage/engine.md#the-read-cache)).
