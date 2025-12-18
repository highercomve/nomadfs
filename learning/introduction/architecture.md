# Deployment Architecture: Storage vs. Client

NomadFS recognizes that not all devices are created equal. A rack-mounted server has different capabilities than an Android phone. To handle this, NomadFS supports two distinct operational modes.

## 1. Storage Node (Full Peer)
*   **Target Devices**: Servers, Desktops, Laptops.
*   **Configuration**: `storage.enabled = true`.
*   **Role**:
    *   **Participates in the DHT**: Helps other nodes find data and peers.
    *   **Stores Blocks**: Hosts data for the swarm.
    *   **On the Ring**: Holds "Virtual Nodes" on the Consistent Hash Ring.
*   **Availability**: Expected to be online frequently.

## 2. Client-Only Node (Roaming/Mobile)
*   **Target Devices**: Android, iOS, low-power IoT.
*   **Configuration**: `storage.enabled = false`.
*   **Role**:
    *   **Gateway**: Acts as an entry point for the user to read/write files.
    *   **Local Encryption**: Encrypts/Decrypts data locally before sending it to the swarm.
    *   **No Storage**: Does **not** store blocks for other peers to save battery and disk space.
    *   **DHT Client**: Issues queries to the DHT but does not store routing table data for others.
*   **On the Ring**: Holds **0 tokens** (it is never selected as a storage destination).

## 3. Implementation: The Shared Library

To support mobile devices efficiently, the core NomadFS engine is compiled as a C-compatible shared library (`libnomad.so` or `.dylib`). 

This allows us to write the complex distributed logic once in **Zig** and access it from:
*   **Android** via JNI (Java Native Interface).
*   **iOS** via Swift/C bindings.
*   **Desktop** via the Zig CLI.

## 4. Node Orchestration

The central entry point for both modes is the `Node` struct defined in `src/root.zig`. This struct acts as the "Controller" that unifies all layers.

### Bottom-Up Initialization
Initialization follows a strict order to satisfy dependencies:
1.  **Network**: The `ConnectionManager` starts first.
2.  **Storage**: The `StorageEngine` initializes (if enabled).
3.  **Discovery**: The DHT `Node` is created, using the `ConnectionManager`.
4.  **Coordinator**: The `BlockManager` is linked to Network, DHT, and Storage.
5.  **Hash Ring**: The `HashRing` is initialized, and the local node adds itself if it provides storage.

### Event Handling: The Serve Loop
The `Node` automatically registers a callback with the `ConnectionManager`. For every new incoming connection:
1.  The `ConnectionManager` triggers the callback.
2.  The `Node` spawns a new thread running the `dht.Node.serve` loop.
3.  This ensures the node is always responsive to `PING` and other DHT queries as soon as it is `start()`ed.

### Lifecycle Methods
*   `init(allocator, cfg)`: Prepares all internal state.
*   `start(port, swarm_key, run_flag)`: Spawns the background listener thread.
*   `bootstrap(peers, swarm_key)`: Connects to initial peers to join the DHT.
*   `deinit()`: Performs a graceful shutdown of all components.
