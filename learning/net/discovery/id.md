# Chapter 2.1: NodeIDs and XOR Math

Every participant in the DHT is identified by a **`NodeID`**
(`src/net/id.zig`). Routing, lookups and the routing table are all built on
it.

## 1. What is a NodeID?

```zig
pub const NodeID = struct {
    pub const len = 32;
    bytes: [len]u8,
    ...
};
```

A NodeID is 256 bits (32 bytes). NomadFS uses the type for several kinds of
ID, made in different ways:

| ID | Constructor | Input |
| :--- | :--- | :--- |
| **Node ID** (DHT, routing table) | `NodeID.fromPublicKey` | BLAKE2s-256 of the node's **X25519 transport public key** (`node.key`) |
| **Device ID** (trust store, pairing, revocation, rotation) | `NodeID.fromPublicKey` | BLAKE2s-256 of the device's **Ed25519 identity public key** (`device.key`) |
| DHT key for a provider record | `NodeID{ .bytes = cid }` | the file's 32-byte root CID (`BlockManager.announce`) |
| Test IDs | `NodeID.generate`, `NodeID.fromData` | random bytes, or SHA-256 of some data (only tests use these) |

The node ID therefore isn't random: it stays the same as long as `node.key`
does, and every peer can check it. The Noise handshake proves possession of
the X25519 key, and the connection reports
`getRemoteNodeID() = fromPublicKey(remote static key)`. A `PING` whose
claimed sender ID doesn't match is refused with `error.PeerIdMismatch`
(`handlePing`, `src/net/discovery/node.zig`). See
[Chapter 1.1](../transport/noise.md) for how the device ID is proven in the
same handshake.

## 2. The XOR Metric

Kademlia defines distance with **exclusive OR**:

$$d(A, B) = A \oplus B$$

read as a 256-bit unsigned number (`NodeID.distance`). XOR is a **metric**:

1.  **Identity**: $d(A, A) = 0$.
2.  **Symmetry**: $d(A, B) = d(B, A)$.
3.  **Triangle inequality**: $d(A, B) + d(B, C) \ge d(A, C)$.

It also has a property routing relies on: for a given $A$ and distance
$\Delta$ there is exactly one $B$ with $d(A, B) = \Delta$.

### Bitwise Interpretation
Two IDs that share a long prefix are close; two that differ in the first bit
are at distance at least $2^{255}$. The **common prefix length** (CPL) is the
number of leading zero bits in the XOR:

```zig
/// 0..256, where 256 means the IDs are equal.
pub fn commonPrefixLen(self: NodeID, other: NodeID) u16 {
    const dist = self.distance(other);
    var zeros: u16 = 0;
    for (dist.bytes) |byte| {
        if (byte == 0) {
            zeros += 8;
        } else {
            zeros += @intCast(@clz(byte));
            break;
        }
    }
    std.debug.assert(zeros <= 256);
    return zeros;
}
```

The CPL is the bucket index in the routing table ([Chapter 2.2](./kbucket.md)).

## 3. Comparing Distances

To sort peers by closeness to a target, NomadFS compares the two XOR
distances byte by byte from the most significant end. The same comparison
appears in `RoutingTable.getClosestPeers` (`kbucket.zig`) and
`LookupState.sortPeers` (`lookup.zig`):

```zig
const dist_a = a.id.distance(target);
const dist_b = b.id.distance(target);
for (0..32) |i| {
    if (dist_a.bytes[i] < dist_b.bytes[i]) return true;  // a is closer
    if (dist_a.bytes[i] > dist_b.bytes[i]) return false;
}
return false;
```

## 4. Random IDs in a Bucket

Bucket refresh needs a target that falls in a given bucket *i*.
`randomIdInBucket(i)` copies our own ID, flips bit *i* (counting from the
most significant bit), and randomizes every bit after it. The result has a
CPL of exactly *i* with our ID.

---

**Next Chapters:**
*   [Chapter 2.2: K-Bucket Management](./kbucket.md)
