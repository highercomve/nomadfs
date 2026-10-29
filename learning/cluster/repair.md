# Chapter 4.5: The Mobile API's `put` and `get`

The C ABI (`nomadfs_put_file` / `nomadfs_get_file`, [Mobile API](../mobile/api.md)) works with whole
files by root CID, outside any folder. It is the last user of DHT **provider records**; everything
else finds holders through the holder registry and placement ([4.2](./holders.md), [4.3](./placement.md)).

## 1. `put`: store and announce

```zig
pub fn put(self: *BlockManager, reader: anytype) ![]const u8 // root CID
```

1. A `DagBuilder` (`.Balanced`) chunks the stream into the local store (kept).
2. `announce(root)` sends `ADD_PROVIDER` to the K = 20 closest peers; with `write_quorum = W > 0`,
   fewer than `W` acknowledgements return `error.QuorumNotReached` (the blocks stay; `put` again
   retries) ([4.6](./quorum.md)). `W = 0` skips it.

Nothing is pushed. An earlier version pushed the whole DAG to the closest peers with `PUT_BLOCK`
(`[storage] replicas`); it was removed with the message: a device stores only blocks it asked for,
and the devices that keep files pull them (the keeper, [4.4](./keeper.md)).

## 2. `get`: copy what's missing, then write

```zig
pub fn get(self: *BlockManager, root: []const u8, writer: anytype, options: walk.ReadOptions) !u64
```

1. If the DAG isn't complete locally, `fetch(root)` names the holders: the nodes in provider records
   (`findProviders`), then the peers the DHT holds closest to the CID, at most eight; with none,
   `error.NoProvider`.
2. It copies the DAG with the keeper's `copy` ([4.4](./keeper.md)): four blocks at a time, the
   fetcher picking the best holder per block, each block verified and kept, held file data skipped.
3. `walk.readFile` writes the file; `options.max_bytes` caps it (`error.FileTooLarge`), and a DAG
   past 2²⁰ blocks is refused (`error.DagTooLarge`), since a small DAG from a peer can describe an
   enormous file.

## 3. What was here before

This chapter used to describe `RepairManager` (`src/cluster/repair.zig`): a DAG copy from **one**
device over one connection (`sync`), and a push of a whole DAG to one device (`push`). Swarm backup,
folder backup and `get` used `sync`; put-time replication used `push`. The keeper replaced the first
(every holder at once, held data not re-read) and the push went away, so the file was removed.

The anti-entropy of the first design (Merkle trees of stored CIDs compared between neighbours) was
never built. Repair today is placement-driven: when membership or `copies` changes, the devices
that now win a file copy it ([4.4](./keeper.md)).

---

**Next Chapters:**
*   [Chapter 4.6: The Write Quorum](./quorum.md)
