# Chapter 4.5: Fetching Whole DAGs (`RepairManager`)

`src/cluster/repair.zig` holds `RepairManager`, which copies a whole Merkle DAG between two devices over one connection. Despite the name it is not a background anti-entropy process: it runs only when something asks for a specific root CID.

## 1. `sync`: Pull a DAG

```zig
pub fn sync(allocator, node: *dht.Node, store: *StorageEngine,
            peer: network.Connection, root_cid: []const u8) !usize
pub fn syncWhile(..., keep_going: ?*const std.atomic.Value(bool)) !usize
```

A depth-first walk from the root:

1.  Pop a CID from the stack; skip it if already visited.
2.  `loadOrFetch`: if the local store has the block, use it; otherwise send `GET_BLOCK` on the connection (`dht.Node.fetchBlock`) and store the reply with `StorageEngine.put`, which **rejects bytes that don't hash to the CID**.
3.  Decode it (`codec.decode`). For a parent or dir block, push its children (`walk.pushChildren`); leaves end the branch.

```text
root ─ have it  → read locally, push children
  ├─ child A ─ missing → GET_BLOCK, verify, store, push its children
  └─ child B ─ have it → read locally, push children
```

Blocks already held are not fetched again, but their children are still checked, so a DAG that was only partly present gets completed. Returns how many blocks were fetched.

Bounds: at most `max_blocks` = 2²⁰ distinct blocks per sync (and `blockBudget(max_bytes)` during file walks, returning `error.DagTooLarge`), because a valid DAG from a peer can still be enormous. `syncWhile` checks `keep_going` between blocks and returns `error.Cancelled` once it turns false.

## 2. `push`: Send a DAG

```zig
pub fn push(allocator, node, store, peer, root_cid) !usize
```

Collects every CID under the root (`walk.collectReachable`, which fails if the local DAG is incomplete, so partial content is never replicated) and sends each block with `PUT_BLOCK`.

Pushed replicas do not require the receiving device to have a trusted-device pairing entry: admission to the swarm (the Noise handshake) is the write authorization. The receiver bounds each pushed block to `max_put_block_len` (`@max((chunker.Params{}).max_size + 1, codec.max_dir_block_len)`), checks the SHA-256 hash against the CID, and verifies that the block does not exceed `quota_mb` (`error.StorageFull`), answering with `STORE_ACK`. Used by `BlockManager.replicate`.

## 3. Who Calls It

| Caller | Function | When |
| :--- | :--- | :--- |
| `BlockManager.fetch` | `sync` | `get` of a DAG that isn't complete locally ([Chapter 4](./overview.md)) |
| `BlockManager.replicate` | `push` | `put` with `replicas > 0` |

Only the mobile C API's `put`/`get` use it now. Every other read and copy goes through the fetcher
and the keeper ([4.1](./fetcher.md), [4.4](./keeper.md)), which pick a holder per block instead of
pulling a whole DAG over one connection, and skip held file data without reading it.

## 4. Not Implemented Yet

The earlier design described here, a Merkle tree over each node's set of stored CIDs, root-hash comparison with neighbours, `WANT` lists, an hourly random-neighbour comparison and reactive repair with hash-ring neighbours, does **not** exist. Repair today is placement-driven: when membership or `copies` changes, the devices that now win a file copy it ([4.4](./keeper.md)). Nothing compares the contents of two block stores. `DiffService` (`src/storage/dag/diff.zig`) computes the blocks one version of a file adds over another, but only its tests call it ([Chapter 3.2](../storage/dag.md)).

---

**Next Chapters:**
*   [Chapter 4.6: The Write Quorum](./quorum.md)
