# Chapter 1.4: Connection Management & Lifecycle

In a truly decentralized network, your node might interact with hundreds of peers over time. Without careful management, these connections would consume all available system resources (memory, file descriptors, and CPU).

The **`ConnectionManager`** (`src/network/manager.zig`) is responsible for the health, efficiency, and cleanup of all peer-to-peer pipes.

## 1. Connection Pooling (Deduplication)

Opening an authenticated Noise connection involves a cryptographic handshake, which is CPU-intensive. To avoid redundant work:

1.  **Lookup before Dial**: When the DHT or another component calls `connectToPeer(address)`, the manager first checks its internal list of active connections.
2.  **Yamux Re-use**: If a connection to that PeerID or Address already exists, the manager returns the existing **Yamux Session**. Components then open a new logical "Stream" over this session instead of dialing a new TCP connection.
3.  **Thread Safety**: A global mutex ensures that two components don't accidentally try to dial the same peer simultaneously.

By using Yamux, NomadFS avoids the high cost of repeated TCP handshakes and Noise cryptographic setups. Multiple concurrent requests (e.g., a DHT lookup and a file transfer) all flow through the same established "Pipe."

## 2. Multiaddress Priority (LAN vs WAN)

A single peer might be reachable via multiple paths (e.g., a Local IP and a Public IP). When connecting to a peer with multiple known addresses, NomadFS uses **Priority Sorting**.

### Priority Scores
1.  **Priority 0 (Loopback)**: `127.0.0.1` or `::1`. Used for testing or local IPC.
2.  **Priority 1 (Private/LAN)**: RFC 1918 ranges (e.g., `192.168.x.x`). These are preferred for speed and zero cost.
3.  **Priority 2 (Public/WAN)**: Routable internet addresses. Used as a fallback if the peers are not on the same network.

The `ConnectionManager` always attempts to dial Priority 0 first, then Priority 1, and finally Priority 2. This ensures that if two devices are on the same WiFi, they will automatically sync over the LAN even if the DHT also reports their public IP.

## 3. Resource Reaping (The Garbage Collector)

A P2P node can't assume peers will stay online forever. Laptops close, mobile apps enter background mode, and routers reboot.

The manager runs a background **Reaper Thread** that periodically (every 10 seconds) scans the connection pool for two conditions:

### A. Closed Connections
If a peer abruptly disconnects (e.g., TCP reset), the Yamux session will mark itself as `closed`. The reaper detects this via `conn.isClosed()` and removes the dead object from memory.

### B. Idle Timeouts
Even if a connection is technically "open", it might be inactive. Keeping an idle connection open prevents other nodes from using that port and wastes resources.
*   **Last Active Tracking**: Every time a component requests a connection via `connectToPeer`, the `last_active` timestamp is updated.
*   **Expiration**: If a connection hasn't been used for 5 minutes (the default `idle_timeout`), the reaper closes it gracefully.

## 3. Implementation Details: Ownership & Cleanup

Managing the lifecycle of connections in a threaded environment requires strict ownership rules to avoid double-frees or use-after-free bugs.

### Separation of Concerns: Close vs. Deinit
We explicitly separate the concept of "Shutting Down" from "Destroying Memory":
1.  **`close()`**: Stops I/O, closes sockets, and signals threads to exit. Safe to call multiple times (idempotent).
2.  **`deinit()`**: Frees the memory allocated for the connection struct. **Must only be called once** by the *owner* of the object.

### Ownership Rules
*   **Connection Manager**: Once you call `manager.addConnection(conn)`, the Manager assumes **full ownership**. It is responsible for calling `deinit()` when the connection is reaped or the manager is stopped.
*   **Caller Responsibility**: If you pass a connection to the manager, you **MUST NOT** call `deinit()` yourself (e.g., via `defer`). This is a common source of bugs in tests.

## 4. Why This Matters for Decentralization

### Resisitance to DOS
By automatically closing idle or dead connections, NomadFS prevents a common class of "Slowloris" or resource exhaustion attacks where a malicious peer opens many connections and never sends data.

### Mobile Optimization
On mobile devices, every active socket drains the battery. The `idle_timeout` ensures that once a file sync or DHT lookup is finished, the radio can eventually sleep.

### Network Agility
Nodes frequently change IP addresses (roaming). By cleaning up old connections quickly, the node stays "agile" and can reconnect to peers at their new locations without being stuck with stale socket state.

---

**Next Chapters:**
*   [Chapter 2.1: DHT Overview: The Phonebook](../dht/overview.md)
