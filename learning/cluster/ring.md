# Chapter 4.3: The Hash Ring (Present, Unused)

`src/cluster/ring.zig` contains a consistent-hash ring. It is compiled, and the node creates one, but **nothing uses it to place or find data**. This chapter documents what the file does so readers of the code aren't misled, and why the project went another way.

## 1. What the Code Does

```zig
const Token = struct { hash: u64, node_id: NodeID };

pub const HashRing = struct {
    tokens: std.ArrayListUnmanaged(Token),
    pub fn addNode(self: *HashRing, node_id: NodeID, weight: usize) !void;
    pub fn getNode(self: *HashRing, key: []const u8) ?NodeID;
};
```

*   **Positions are 64-bit**: each token is `FNV-1a-64(node_id ‖ i)` for `i` in `0..weight`. The ring is the `u64` space, not a 256-bit one.
*   `addNode` appends `weight` tokens and sorts them by hash.
*   `getNode(key)` hashes the key with FNV-1a-64 and binary-searches for the first token at or after it, wrapping to the first token.

There is no preference list, no removal of nodes and no hand-over on churn.

## 2. How the Node Uses It

`src/root.zig` creates a `HashRing` and, when storage is enabled, adds **only the local node**, with **10** tokens. No other node is ever added, and `getNode` has no caller. The ring has no effect on where data goes.

## 3. Where Placement Actually Happens

When `BlockManager` replicates a new file (`replicas > 0`) or looks for copies of one, it uses the **Kademlia XOR distance** of the DHT: the K closest peers to the root CID (`dht.Node.closestFor`). See [Chapter 4](./overview.md) and [Kademlia lookups](../net/discovery/lookup.md). Shares and the swarm folder don't place data at all: a file's blocks stay on the device that owns or added it, plus whoever has read it and any swarm backup device.

## 4. Not Implemented Yet

A ring-based design (N clockwise successors as replicas, virtual nodes per device, data hand-over when devices join or leave) is **not planned** any more. [ROADMAP.md](../../ROADMAP.md) moves away from a global hash ring toward a personal device mesh with **directed sync and backup policies** (choose which device keeps what), which are planned but not implemented. `ring.zig` is a leftover of the earlier design.

---

**Next Chapters:**
*   [Chapter 4.4: Vector Clocks (unused)](./vectors.md)
