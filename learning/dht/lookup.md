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

## 4. Handling Failures and Churn

In a P2P network, nodes go offline all the time. NomadFS handles this at multiple levels:

1.  **Detection**: If an RPC call (e.g., `FIND_NODE`) fails due to a connection error or timeout, the peer is considered dead for the duration of that lookup.
2.  **Lookup State Isolation**: The `LookupState` maintains a `failed` set. Once a node fails to respond, it is moved to this set and will **never** be re-added to the current search, even if another peer suggests it.
3.  **Routing Table Cleanup**: Failed peers are immediately removed from the routing table via `markDisconnected`. This ensures that subsequent lookups don't waste time on known-dead nodes.
4.  **Automatic Continuity**: Because lookups query $\alpha$ nodes in parallel and maintain a list of $K$ candidates, the search automatically "routes around" the failure by selecting the next best available peer.

This multi-layered approach makes the discovery process resilient to high levels of churn.

## 5. Integration Testing

The robustness of the lookup algorithm is verified by `tests/dht/churn_test.zig`, which:
1.  Spawns a 10-node network.
2.  Populates routing tables so Node A knows about Node B (the closest to a target).
3.  Abruptly stops Node B.
4.  Verifies that Node A can still find the *second* closest node to the target by correctly identifying Node B's failure and continuing the search.

## 5. Value Lookup

Looking up a value (`lookupValue`) follows the same iterative process as finding a node, but uses `FIND_VALUE` RPCs instead of `FIND_NODE`.

*   If a peer returns **Closer Peers**, the search continues as normal, adding those peers to the list.
*   If a peer returns the **Value**, the search terminates immediately, and the value is returned to the caller.

This optimization allows data to be found often before the search converges on the absolutely closest nodes.

---

**Next Chapters:**
*   [Chapter 2.4: DHT RPC and Serialization](./rpc.md)
