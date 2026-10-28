# Chapter 4.2: The Write Quorum

`src/cluster/quorum.zig` defines the classic `N`, `W`, `R` triple, but the node uses only one of the three numbers, and that one means something narrower than in Dynamo-style systems.

## 1. The Code

```zig
pub const QuorumConfig = struct {
    N: u8 = 3, // never read
    W: u8 = 1, // used
    R: u8 = 1, // never read
};

pub fn isWriteSatisfied(config: QuorumConfig, successful_writes: u8) bool;
pub fn isReadSatisfied(config: QuorumConfig, successful_reads: u8) bool; // never called
```

`src/root.zig` builds the `BlockManager` with `.quorum = .{ .W = cfg.storage.write_quorum }` and `.replication = cfg.storage.replicas`. `N` and `R` keep their defaults and nothing reads them.

## 2. What `W` Counts

`W` (`write_quorum`, default **1** in `src/config.zig`) is the number of peers that must acknowledge the **provider record** for a new file's root CID (`ADD_PROVIDER`, answered with `STORE_ACK`) in `BlockManager.announce`:

| `W` | Behaviour of `BlockManager.put` |
| :--- | :--- |
| `0` | no announcement at all; `put` is purely local |
| `≥ 1` | `addProvider` sends `ADD_PROVIDER` to the K = 20 closest peers; if fewer than `W` acknowledge (including zero peers while offline), `put` returns `error.QuorumNotReached` |

It does **not** count copies of the data. The blocks are always written locally first and stay there when the quorum fails; a later `put` of the same file is idempotent and only retries the announcement.

The app writes `write_quorum = 0` into the configuration it generates (`nomadfs-gui/src/commands.zig`), so an app device never fails a write for lack of peers. The mobile C ABI documents the other case: `nomadfs_put_file` returns `NULL` when the quorum isn't reached, and the blocks are kept.

## 3. What Plays the Role of `N`

The number of copies is `replicas` (`[storage] replicas`, default **0**, capped at `config.max_replicas` = 20), passed to `BlockManager` as `replication`. With `replicas > 0`, `put` pushes the DAG to that many of the Kademlia-closest peers to the root CID, synchronously, and only logs failures ([Chapter 4](./overview.md)). The app's generated configuration sets `replicas = 1`.

## 4. Reads

There is no read quorum. `BlockManager.get` reads locally when the DAG is complete, otherwise copies it from the **first** source that can serve the whole DAG ([Chapter 4.1](./repair.md)). Every block is verified against its CID, so one source is enough: a wrong block can't pass as a right one.

## 5. Availability during Partitions

*   With `W = 0` a device can always store a file, connected or not.
*   With `W ≥ 1` an offline `put` fails with `QuorumNotReached` even though the data is stored; retry after reconnecting.
*   A file can be read from any device that holds its blocks. The swarm folder adds *backup devices* that hold a copy of every file ([The Swarm Folder](../fs/swarm.md)).

## 6. Not Implemented Yet

*   **Read quorums (`R`)** and **replication factor `N`** as in Dynamo.
*   **Background re-replication** when a replica disappears, and periodic re-announcement of provider records (they expire after 24 h).

---

**Next Chapters:**
*   [Chapter 4.3: The Hash Ring (unused)](./ring.md)
