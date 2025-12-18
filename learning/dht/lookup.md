# Chapter 2.3: Iterative Search

Iterative search (or "lookup") is the algorithm Kademlia nodes use to find a specific NodeID or a file block in the network. It is the core "routing" mechanism of NomadFS.

## 1. The Strategy: Convergence

The goal is to find the $K$ nodes closest to a target ID.
1.  **Start Local**: We pick the $K$ nodes closest to the target from our own routing table.
2.  **Parallel Queries**: We send `FIND_NODE` requests to the $\alpha$ (usually 3) closest nodes.
3.  **Refine**: When a peer replies, they give us a list of nodes *they* know that are even closer to the target.
4.  **Repeat**: we add these new nodes to our list and query the new "best" ones.

This process continues until we converge—meaning we've queried the closest nodes we know about and none of them can give us anyone closer.

## 2. Managing Search State

The `LookupState` struct (`src/dht/lookup.zig`) manages this convergence. It keeps track of:
*   **Target**: The ID we are looking for.
*   **Best Peers**: A sorted list of the closest nodes found so far.
*   **Queried/In-Flight**: Sets to ensure we don't query the same node twice or overwhelm our connection pool.

## 3. The Algorithm in Code

```zig
pub fn isFinished(self: *LookupState) bool {
    // We are done if we have queried the top K closest nodes
    // and there are no more "better" nodes to try.
    if (self.in_flight.count() > 0) return false;

    var queried_count: usize = 0;
    for (self.best_peers.items) |p| {
        if (p.queried) {
            queried_count += 1;
        } else {
            return false;
        }
        if (queried_count >= K) return true;
    }
    return true;
}
```

## 4. Handling Failures

In a P2P network, nodes go offline all the time. If a node fails to respond to a `FIND_NODE` request:
1.  We remove it from our `best_peers` list.
2.  We mark it as "dead" in our routing table (or initiate an eviction check).
3.  The lookup continues with the next best known peer.

This makes the search extremely resilient. Even if many nodes in our path are offline, we only need *one* path to survive to find the target.

---

**Next Chapters:**
*   [Chapter 2.4: DHT RPC and Serialization](./rpc.md)
