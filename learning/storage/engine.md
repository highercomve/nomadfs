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
    // The read cache (below)
    pub fn putCached(self: *StorageEngine, block: Block) !void;
    pub fn pin(self: *StorageEngine, cid: *const [32]u8) !void;
    pub fn setCacheLimit(self: *StorageEngine, limit: ?u64) !void;
    pub fn cacheStats(self: *StorageEngine) CacheStats;
    pub fn clearCache(self: *StorageEngine) !u64;
};
```

Kept blocks are never deleted. Only the read cache evicts.

### `put`
1.  Hashes `block.data` with SHA-256 and returns `error.HashMismatch` if it isn't `block.cid`. Nothing that doesn't match its name gets in, whether it came from the local builder or from a peer.
2.  If a file with that CID already exists, returns without writing (content addressing makes `put` idempotent and gives deduplication for free).
3.  **Quota check**: If a capacity quota is set via `setQuota` (configured with `quota_mb` under `[storage]`), verifies `used_bytes + block_size <= quota_bytes`. If the store would exceed the quota, `put` fails with `error.StorageFull`, writing nothing.
4.  Otherwise writes `<cid>.tmp`, then renames it to `<cid>`, and tracks added bytes in `used_bytes`. A crash can leave a stray `.tmp` file but never a truncated block under a valid name.

### `get`
1.  Opens `<cid>`, then `cache/<cid>` (a cache hit refreshes the file's mtime). If neither exists and an `External` source is set, asks it instead (below). Returns `null` if none has the block.
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
*   [Chapter 4: The Distribution Layer](../cluster/overview.md)

## The read cache

The store keeps two kinds of blocks apart:

| Area | Holds | Evicted |
|---|---|---|
| `<storage_path>/<cid>` (kept) | This device's own data: swarm folder files it wrote, its shares' parent and dir blocks, backups, replicas pushed to it, `nomadfs_put_file` | Never |
| `<storage_path>/cache/<cid>` (read cache) | Blocks fetched from another device only to be read (`Remote.load`: the app, the mount, read-ahead) | Least recently read first |

- **`putCached`** verifies the hash like `put`, skips blocks already held in either area, and writes into
  `cache/`. When the cache passes its limit (`cache_mb` under `[storage]`, default **2048 MiB**, `0` = no
  limit), it deletes the least recently read blocks until it is under **90 %** of the limit, so a full
  cache doesn't evict on every new block.
- **Recency is the file's mtime:** a cache hit in `get` sets it to now, so mtime order is read order.
- **`pin`** moves a cached block into the kept area, when the device takes responsibility for it: a
  swarm backup that finds a file's blocks already cached, a repair that reuses cached blocks. A kept
  `put` of a block that is also cached removes the cached copy.
- **`clearCache`** deletes everything in `cache/` and nothing else. **`cacheStats`** counts the
  directory each time, so a cache cleared by another process (the command line while the app runs)
  reads right.
- `quota_mb` applies to kept blocks only; the read cache has its own limit.

Command line: `nomadfs --cache` shows the size and limit, `nomadfs --clear-cache` empties it. The app
shows both under **About → Read cache**, with the limit as a setting. The C ABI has
`nomadfs_cache_info`, `nomadfs_cache_clear` and `nomadfs_cache_set_limit`.

### Blocks stored before the cache existed

Before 0.2.0 every fetched block went into the kept area. On its first start a 0.2.0 node sorts them
once (`Node.sortLegacyCache`, `src/root.zig`): after every share's first scan has finished, however
long that takes (a share whose folder is gone and so never gets a root is given up on after 30 minutes),
it collects the blocks reachable from its shares' roots and from the swarm folder files it wrote or
backed up (`walk.addStoredReachable`, which reads stored block files only, never a shared file), and
moves every other kept block into `cache/` (`demoteExcept`). A `cache/.sorted-v1` marker keeps it from
running again. Blocks received as replicas can't be told from read blocks afterwards and are moved
too; the device that wrote them still keeps its own copy.

