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

## 4. Reliability: Churn and the Replacement Cache

Nodes in a P2P network are constantly joining and leaving ("churn"). If we just discarded new nodes when a bucket is full, we might miss out on a stable peer just because our bucket is full of stale ones.

To handle this, NomadFS implements a **Replacement Cache** for each bucket.

### The Algorithm
1.  **Bucket Full?** If we find a new node and the main bucket ($K=20$) is full, we don't discard it yet.
2.  **Cache It:** We check the **Replacement Cache**. If it has space, we add the new node there.
3.  **Eviction & Promotion:** When a node in the main bucket fails (e.g., fails to respond to a query or disconnects), we remove it.
4.  **Instant Refill:** Immediately after removal, we look at the Replacement Cache. If it has peers, we **promote** the most recently seen one into the main bucket.

This ensures that our routing table remains "saturated" with live peers, even if many nodes suddenly go offline. This strategy makes the DHT incredibly resilient to network instability.

## 5. Inspecting the Table

NomadFS provides a `dump()` method on the `RoutingTable` to inspect its current state, which is useful for debugging and monitoring the network topology.

```zig
pub fn dump(self: *RoutingTable) void {
    std.debug.print("--- Routing Table Dump ---\n", .{});
    // ... iterates and prints active buckets and peers ...
}
```

## 6. Implementation Note: MVP vs. Production

When building a DHT, one often starts with a "Minimum Viable Product" (MVP). In NomadFS, our MVP implementation used a simple **Static Bucket Array** without a replacement cache.

*   **MVP Behavior**: If a bucket was full ($K=20$) and a new peer arrived, the new peer was simply **discarded**.
*   **The Flaw**: This assumes the 20 peers currently in the bucket are "good." In reality, peers often go offline without warning. If we keep stale peers and discard new (live) ones, our routing table slowly "rots," leading to lookup failures.
*   **The Fix**: The **Replacement Cache** acts as a waiting room. It allows us to hold onto new, live peers and swap them in the moment an old peer dies. This transforms the system from "static and decaying" to "dynamic and self-healing."
