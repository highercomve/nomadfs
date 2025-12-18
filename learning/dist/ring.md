# Chapter 5.1: Consistent Hashing & The Ring

To distribute data across a dynamic swarm of nodes where members frequently join and leave, NomadFS uses **Consistent Hashing**. This ensures that when the swarm changes, only a small fraction of data needs to be moved.

## 1. The Circular ID Space

Both **NodeIDs** and **Data CIDs** are 256-bit numbers. We visualize this space as a circle (the "Ring") ranging from $0$ to $2^{256}-1$.

*   Nodes are placed on the ring based on their NodeID.
*   Data blocks are placed on the ring based on their CID.

## 2. Virtual Nodes (Tokens)

If we only placed each node on the ring once, the distribution of data would be very uneven. Some nodes would happen to be responsible for a huge segment of the ring, while others would have almost none.

NomadFS uses **Virtual Nodes** (or "Tokens") to solve this:
*   Each physical node is mapped to multiple points on the ring (default is 256 tokens for a full storage node).
*   Powerful nodes can be assigned more tokens (higher weight).
*   Client-only nodes (phones) are assigned **zero tokens**, ensuring they are never chosen to store blocks for the swarm.

## 3. Finding the Responsible Node

To find which node stores a specific CID:
1.  Calculate the CID's position on the ring.
2.  Travel clockwise from that position until you hit a token.
3.  The node that owns that token is the primary owner of the data.

```zig
pub fn getNode(self: *HashRing, key: []const u8) ?NodeID {
    // ... hash the key ...
    // ... binary search for the first token >= hash ...
    // ... return the owner's NodeID ...
}
```

## 4. Replication (The Preference List)

For reliability, we don't just store data on one node. We store it on $N$ distinct nodes.
Starting from the CID's position, we continue traveling clockwise and collect the first $N$ unique physical nodes we encounter. This set is called the **Preference List** or **Replica Set**.

## 5. Handling Churn

When a new node joins:
*   It takes over some tokens on the ring.
*   It becomes the new owner for some CIDs that were previously owned by its clockwise neighbor.
*   The neighbor can now delete that data (or keep it as a cache).

Because of consistent hashing, only the data that is *actually* moving to the new node needs to be transferred. The rest of the network is unaffected.

---

**Next Chapters:**
*   [Chapter 4.3: Quorum Logic & Availability](../sync/quorum.md)
