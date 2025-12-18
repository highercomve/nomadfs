# Chapter 2.2: K-Bucket Management

The **Routing Table** is the "phonebook" that each node keeps. Because a distributed system might have millions of nodes, we cannot store everyone. Instead, we use **K-Buckets**.

## 1. The Structure

The routing table is divided into 256 "buckets" (one for each possible bit position in the 256-bit ID).

*   **Bucket $i$** stores information about nodes whose XOR distance from us is between $2^i$ and $2^{i+1}$.
*   In practice, this means Bucket $i$ contains nodes that share exactly $255 - i$ prefix bits with our own ID.

## 2. The Constant $K$

Every bucket has a maximum capacity called **$K$**. In the original Kademlia paper and in NomadFS, **$K = 20$**.

*   If we find a new node and its bucket is not full, we add it.
*   If the bucket is full, we must decide whether to keep the old nodes or replace them.

## 3. Finding the Right Bucket

To find which bucket a node belongs to, we calculate the Common Prefix Length (CPL) between our ID and the peer's ID.

```zig
pub fn addPeer(self: *RoutingTable, peer: PeerInfo) !void {
    std.debug.assert(!peer.id.eql(self.local_id));
    const cpl = self.local_id.commonPrefixLen(peer.id);
    
    // cpl is 0..256. If cpl is 256, ids are identical (handled by assert).
    // Index must be < 256.
    const index = @min(cpl, 255);
    _ = try self.buckets[index].add(peer);
}
```

## 4. Reliability and Eviction

Kademlia prefers **older nodes**. Studies of P2P networks show that the longer a node has been online, the more likely it is to stay online.

When a bucket is full and a new node is seen:
1.  We **Ping** the oldest node in the bucket.
2.  If the oldest node responds, it is moved to the "tail" (most recently seen), and the new node is discarded.
3.  If the oldest node fails to respond, it is evicted, and the new node is added.

This strategy makes the DHT incredibly resilient to "churn" (nodes constantly joining and leaving).

## 5. Inspecting the Table

NomadFS provides a `dump()` method on the `RoutingTable` to inspect its current state, which is useful for debugging and monitoring the network topology.

```zig
pub fn dump(self: *RoutingTable) void {
    std.debug.print("--- Routing Table Dump ---\n", .{});
    // ... iterates and prints active buckets and peers ...
}
```
