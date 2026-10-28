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

## 1. Mounting without root (`mountWithFusermount`)

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

## 2. The serve loop

`Mount.serve(mountpoint)` is a single loop on one thread:

```
loop:
    n = read(/dev/fuse, request_buffer)     // one request: InHeader + body
    EINTR / ENOENT / EAGAIN -> retry;  ENODEV -> unmounted, return
    dispatch(request)                       // handle it and write exactly one reply
```

`dispatch` switches on `InHeader.opcode`:

| Opcodes | Handler |
| :--- | :--- |
| `INIT` | `opInit`: negotiates protocol **7.31** (minor = min(kernel's, 31)); keeps only `FUSE_ATOMIC_O_TRUNC` and `FUSE_BIG_WRITES`; `max_write` 128 KiB |
| `LOOKUP`, `GETATTR`, `ACCESS`, `STATFS` | attributes and names |
| `OPENDIR`, `READDIR`, `RELEASEDIR` | listings |
| `OPEN`, `READ`, `RELEASE`, `FLUSH`, `FSYNC` | file reads (and swarm commits on `RELEASE`) |
| `CREATE`, `WRITE`, `SETATTR`, `MKDIR`, `UNLINK`, `RMDIR`, `RENAME`, `RENAME2` | swarm folder writes |
| `FORGET`, `BATCH_FORGET`, `INTERRUPT` | no reply expected |
| `DESTROY` | reply and leave the loop |
| `GETXATTR`, `LISTXATTR`, anything else | `ENOSYS` |

Replies carry `entry_valid` / `attr_valid` = `cache_seconds` = **1 s**, so the kernel re-asks
soon and changes on other devices show up quickly.

## 3. The inode model

```zig
const Kind = enum { root, device, dir, file, swarm_dir, swarm_file };
```

- `inodes` is an array indexed by inode number − 1; inodes are **never reused** while mounted.
- `children` maps `(parent inode, name)` to an inode, so a path keeps its inode number.
- Share inodes carry `device` (an index into `devices`) and `cid`; swarm inodes carry `swarm_path`
  and `author` (the device to fetch from first).
- The device list (`refreshDevices`) comes from `fs.remote.knownPeers`, each with a `Remote`
  loader and its `GET_SHARES` listing. It is refreshed at most every **5 s**
  (`device_refresh_ns`). `Swarm/` appears when the node has a swarm folder.

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
    path: []u8,       // path inside the swarm folder
    staging: [:0]u8,  // <storage_path>.swarm.json.staging/<fh>.part
    fd: i32,
    dirty: bool,
};
```

1. **`OPEN` with write access, or `CREATE`** → `openForWrite` / `newHandle` creates the staging
   file (mode 0600). Opening an existing file **without `O_TRUNC`** first copies its current
   content in through `SwarmFolder.readAt` (fetching blocks if needed), so appends and in-place
   edits work.
2. **`WRITE`** → `pwrite` into the staging file; the inode's size and mtime are updated at once.
3. **`SETATTR` with a size** → `ftruncate` on the open handle; a truncate with no open file is
   staged, cut and committed immediately.
4. **`RELEASE`** (last close) → `commit`: if dirty, `SwarmFolder.addFile(dir, name, staging)`
   chunks the staged bytes into the block store and records **one** manifest edit. Other devices
   never see a half-written file. The staging file is removed.

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
| `rmdir` on a non-empty swarm folder | `ENOTEMPTY` |
| Extended attributes | `ENOSYS` |
| Swarm errors (`errnoFor`) | `FileNotFound` → `ENOENT`, `PathAlreadyExists` → `EEXIST`, `InvalidPath` → `EINVAL`, `NameTooLong` → `ENAMETOOLONG`, `ReadOnly` → `EROFS`, other → `EIO` |
| A block no device can serve | `EIO` on that read |

## 7. Limits

- Linux only (`/dev/fuse`, `fusermount3`). The app's Mount tab is shown only where mounting works.
- One request at a time: a read that waits on a slow device holds up the requests queued behind it.
- No extended attributes, symlinks or hard links. Mode and time changes (`chmod`, `touch`,
  `cp -p`) are accepted but not stored; the modes shown are fixed.

> **Not implemented yet:** a size-limited (LRU) block cache for mounted devices. Fetched blocks
> currently stay in the store indefinitely. Planned in [ROADMAP.md](../../ROADMAP.md) (Phase 4).
