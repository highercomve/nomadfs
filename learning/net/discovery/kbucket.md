# Chapter 2.2: K-Bucket Management

The **routing table** is the "phonebook" each node keeps. A network can be
far larger than any one node should track, so Kademlia keeps a few peers at
every distance, in **k-buckets**. The code is in
`src/net/discovery/kbucket.zig`.

## 1. The Structure

```zig
pub const K = 20;
pub const MAX_PEER_ADDRESSES = 8;

pub const RoutingTable = struct {
    local_id: NodeID,
    buckets: [256]Bucket, // Bucket i stores peers with common prefix length i
    allocator: std.mem.Allocator,
};
```

**Bucket *i* holds peers whose ID shares exactly *i* leading bits with ours**
(common prefix length = *i*, see [Chapter 2.1](./id.md)). In distance terms,
bucket *i* covers XOR distances in $[2^{255-i}, 2^{256-i})$. Bucket 0 holds
the half of the ID space furthest from us; each later bucket covers half the
range of the one before.

```
our ID:   1011 0110 ...
bucket 0: 0xxx xxxx ...   (differs in bit 0, half of all IDs)
bucket 1: 11xx xxxx ...   (same bit 0, differs in bit 1)
bucket 2: 100x xxxx ...
...
```

## 2. Peer Records

```zig
pub const PeerInfo = struct {
    id: NodeID,
    addresses: [MAX_PEER_ADDRESSES]network.Address = undefined,
    sources: [MAX_PEER_ADDRESSES]AddrSource = [_]AddrSource{.observed} ** MAX_PEER_ADDRESSES,
    learned: [MAX_PEER_ADDRESSES]i64 = [_]i64{0} ** MAX_PEER_ADDRESSES,
    addrs_count: u8 = 0,
    last_seen: i64,
};
```

A peer can have up to **8 addresses**, each tagged with where it came from:
`observed` (the address of an authenticated connection, with the port the peer
says it listens on), `announced` (an address the peer itself listed in a
`PING`/`PONG`) or, only inside a running lookup, `hearsay`. When the 8 slots
are full a more reliable address replaces the weakest, oldest one; hearsay
never replaces anything and is never stored. `getBestAddress` still picks the
lowest `network.addressPriority` (see
[Chapter 1.4](../transport/management.md#4-address-priority-lan-vs-wan)).

## 3. Finding the Right Bucket

```zig
fn bucketFor(self: *RoutingTable, peer_id: NodeID) *Bucket {
    const cpl = self.local_id.commonPrefixLen(peer_id);
    return &self.buckets[@min(cpl, 255)];
}

pub fn addPeer(self: *RoutingTable, peer: PeerInfo) !bool {
    if (peer.id.eql(self.local_id)) return false; // never store ourselves
    return try self.bucketFor(peer.id).add(peer);
}
```

Peer IDs come from the network, so our own ID is rejected with a normal
`false` rather than an assertion.

## 4. The Constant K and the Replacement Cache

Each bucket has a main list (`peers`, at most **K = 20**) and a
**replacement cache** (`replacements`, also at most 20). Both are ordered
from least to most recently seen. `Bucket.add(peer)`:

1.  **Already in the main list**: update `last_seen`, merge addresses, and
    move it to the tail. Returns `true`.
2.  **Already a replacement**: the same, inside the cache. Returns `false`.
3.  **Main list has room**: append. Returns `true`.
4.  **Main list full**: append to the replacement cache, dropping the oldest
    replacement if the cache is full too. Returns `false`.

`Bucket.remove(id)` (called through `RoutingTable.markDisconnected`) removes
a peer from the main list and **promotes** the most recently seen
replacement into it. Removing a replacement just drops it.

### Who decides that a peer is dead?
`discovery.Node` drives this (`src/net/discovery/node.zig`):

*   **`addVerifiedPeer`**: when `addPeer` returns `false` (the bucket is
    full), the node pings the bucket's least recently seen peer across all its
    known addresses (`pingLruAndEvict`). If none answer, it is removed and a
    replacement is promoted.
*   **Lookups**: a peer whose known addresses fail a `FIND_NODE` or
    `FIND_VALUE` is removed with `markDisconnected` ([Chapter 2.3](./lookup.md)).

Only *verified* data is stored: the address of an authenticated `PING`/`PONG`
or lookup reply, and the addresses the peer announces itself after filtering
([Chapter 2.4](./rpc.md#6-safety-and-validation)). Addresses merely listed in
someone else's reply are not.

## 5. Bucket Refresh

Every bucket records `last_updated`, set whenever `add` runs on it.
`discovery.Node.refreshBuckets()` (called every 60 s by `runBootstrap` in
`src/root.zig`) looks up `randomIdInBucket(i)` for every bucket not updated
for an hour (3600 s). That repopulates quiet regions of the ID space.

## 6. Other Operations

*   `getClosestPeers(target, count)`: copies every main-list peer, sorts by
    XOR distance to `target`, and returns the first `count` (the caller frees
    the slice). This answers `FIND_NODE` and seeds lookups.
*   `getAllPeers()`: every main-list peer. The swarm folder syncs with these
    (`fs.remote.knownPeers`).
*   `contains`, `getPeer`: main list only; replacements don't count.\n*   `dump()`: prints every non-empty bucket with its peers, addresses and
    replacement count.

The table has no lock of its own. `discovery.Node.mutex` guards it.

---

**Next Chapters:**
*   [Chapter 2.3: Iterative Search](./lookup.md)
