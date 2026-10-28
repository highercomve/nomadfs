# Chapter 3.3: The Disk Engine

`StorageEngine` (`src/storage/engine.zig`) is the component that writes blocks to disk and reads them back. It is a deliberately simple flat-file store.

## 1. Flat-File CID Storage

Blocks live in one directory: `storage_path` in `nomadfs.conf` (a leading `~` is expanded to `$HOME`; the directory is created if missing). Each block is a file whose **name is the lower-case hex CID** and whose content is the encoded block (tag byte + body):

```text
<storage_path>/
├── 0a2f1b…   (64 hex characters)
├── 3e4d9c…
└── f7a201…
```

Next to it, other components keep their own files: the swarm folder's manifest `<storage_path>.swarm.json`, its backup record `<storage_path>.swarm.json.backup` and the FUSE staging directory `<storage_path>.swarm.json.staging/` (see [The Swarm Folder](../fs/swarm.md) and [The FUSE Mount](../fs/fuse.md)).

## 2. The API

```zig
pub const StorageEngine = struct {
    root_dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    external: ?External = null,
    used_bytes: u64 = 0,
    quota_bytes: ?u64 = null,

    pub fn init(allocator, path: []const u8) !StorageEngine;
    pub fn setQuota(self: *StorageEngine, bytes: u64) !void;
    pub fn put(self: *StorageEngine, block: Block) !void;
    pub fn has(self: *StorageEngine, cid: []const u8) bool;
    pub fn get(self: *StorageEngine, cid: []const u8, allocator) !?Block;
};
```

That is the whole interface: there is **no delete**.

### `put`
1.  Hashes `block.data` with SHA-256 and returns `error.HashMismatch` if it isn't `block.cid`. Nothing that doesn't match its name gets in, whether it came from the local builder or from a peer.
2.  If a file with that CID already exists, returns without writing (content addressing makes `put` idempotent and gives deduplication for free).
3.  **Quota check**: If a capacity quota is set via `setQuota` (configured with `quota_mb` under `[storage]`), verifies `used_bytes + block_size <= quota_bytes`. If the store would exceed the quota, `put` fails with `error.StorageFull`, writing nothing.
4.  Otherwise writes `<cid>.tmp`, then renames it to `<cid>`, and tracks added bytes in `used_bytes`. A crash can leave a stray `.tmp` file but never a truncated block under a valid name.

### `get`
1.  Opens `<cid>`. If there is no such file and an `External` source is set, asks it instead (below). Returns `null` if neither has the block.
2.  Re-hashes the bytes and returns `error.CorruptBlock` if they don't match the CID, so disk corruption is reported, not returned as data.

The returned `Block.data` is owned by the caller.

### `has`
True if the block file exists or the external source has the CID. It does not verify content.

### Concurrency
One `mutex` guards file operations and `used_bytes` updates; hashing in `get` happens after the lock is released.

## 3. External Blocks: the Filestore Hook

```zig
pub const External = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx, cid: *const [32]u8, allocator) anyerror!?[]u8,
    hasFn: *const fn (ctx, cid: *const [32]u8) bool,
};
```

Shared folders are not copied into the store. The share scanner records where each leaf's bytes are (file, offset, length), and `src/fs/filestore.zig` serves those leaves through this hook, re-hashing the bytes on every read. Peers fetch shared files with the same `GET_BLOCK` as any other block. See [Shared Folders](../fs/shares.md).

## 4. Who Uses the Engine

*   **`GET_BLOCK` / `PUT_BLOCK`** handlers in `src/net/discovery/node.zig` read from and write to the store. `PUT_BLOCK` accepts replicas from any authenticated swarm member (swarm admission is the write authorization; no trusted-device entry required) up to `max_put_block_len`. Pushed blocks are verified against their CID and quota before storage.
*   **`BlockManager`** stores new files and fetched DAGs ([Chapter 4](../cluster/overview.md)). Subtree traversals and fetches enforce `blockBudget(max_bytes)`, returning `error.DagTooLarge` if the visit count exceeds budget.
*   **Remote browsing** (`src/fs/remote.zig`) caches every fetched block here, so a file read once reads offline afterwards.
*   **The swarm folder** stores added files in full here.

## 5. Storage Disabled

`[storage] enabled = false` leaves the node without a `StorageEngine` (`Node.store == null`). Then `BlockManager.put`/`get` return `error.StorageDisabled`, `GET_BLOCK` replies with no data, and there are no shares and no swarm folder. It is not a "client-only" mode that still reads and writes through peers.

## 6. Not Implemented Yet

*   **Garbage collection / delete**: blocks of deleted or replaced files stay until removed by hand.
*   **Encryption at rest**: blocks are stored as plaintext. Only the transport is encrypted ([Noise](../net/transport/noise.md)); anyone who can read `storage_path` can read the blocks.
*   **Sharding** the flat directory into subdirectories (e.g. `ab/cdef…`) for very large stores.

---

**Next Chapters:**
*   [Chapter 4: Block Exchange & Replication](../cluster/overview.md)
