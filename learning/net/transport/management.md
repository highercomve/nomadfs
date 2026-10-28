# Chapter 1.4: Connection Management & Lifecycle

A node talks to many peers over time. The **`ConnectionManager`**
(`src/net/transport/manager.zig`) keeps one pooled connection per peer, dials
addresses in a sensible order, retires dead or idle connections, and hands
each new connection to whoever serves it.

## 1. Creating and Starting a Manager

*   `ConnectionManager.init` / `create` load the node's X25519 transport key
    with `loadOrCreateKey`: the configured `key_path` if set, otherwise
    `node.key` in the current directory, otherwise `~/.nomadfs/node.key`. A
    key is created only where none exists. An existing key that is corrupt or unreadable is an
    error: silently replacing it would change the node's identity.
    `initExplicit` / `createExplicit` take a key directly (tests, invites).
*   `node_id = NodeID.fromPublicKey(keypair.public_key)`: BLAKE2s-256 of the
    transport public key.
*   `setDeviceAuthenticator(auth)` attaches the device identity and trust
    store, so every handshake carries and checks a
    [device hello](./noise.md#4-device-identity-the-device-hello-srcdeviceauthzig).
*   `start()` spawns the **reaper** thread. `listen(cfg, running)` starts the
    LAN announcer ([Chapter 1.5](./mdns.md)), the UPnP thread
    ([Chapter 1.6](./nat.md)), and the TCP accept thread.
*   `setConnectionHandler(ctx, handler)` sets the function that runs, on its
    own thread, for every connection added to the pool. In a node it is
    `discovery.Node.serve` (`src/root.zig`), which accepts that connection's
    Yamux streams. `setDiscoveryHandler` receives peers found on the LAN.

## 2. Reference Counting

A `network.Connection` (`TcpConnectionImpl` in `tcp.zig`) is **reference
counted**:

*   `retain()` adds a reference; `deinit()` drops one. The last `deinit()`
    joins the Yamux reader thread and frees the session, its streams, the
    Noise buffers and the socket.
*   `close()` only signals shutdown: it shuts the socket down and wakes every
    waiter. It is safe while other threads still hold references.

The manager holds one reference to each pooled connection. Every function
that returns a connection returns a **new** reference that the caller must
release:

```zig
const conn = try manager.connectToPeer(addr, swarm_key, expected_node_id);
defer conn.deinit(); // drops the caller's reference; the pool keeps its own
```

This applies to `connectToPeer`, `connectToPeerMulti` and `getConnection`.
`addConnection(conn)` is different: on success the manager takes over the
caller's reference, and on error the caller still owns it and nothing was
registered.

## 3. Connection Pooling

`connectToPeer(address, swarm_key, remote_node_id)`:

1.  **Look up first.** Under the mutex, `findConnectionLocked` looks for a
    live connection. With an expected node ID only the *authenticated* ID
    counts, because another node may now sit at a known address. Without
    one, any matching address counts. A match gets `last_active` refreshed
    and is returned with `retain()`.
2.  **Dial.** The mutex is **released** before dialing, so a slow handshake
    doesn't block other callers. Two threads dialing the same new peer at
    the same moment can therefore both connect, and the pool briefly holds
    two connections. The spare one is reaped once idle.
3.  **Check.** If a node ID was expected and the handshake proved a different
    one, the call fails with `error.PeerIdMismatch`.
4.  **Register.** One reference goes to the pool (`addConnection`, which also
    starts the connection handler thread), one to the caller.

Incoming connections take the same `addConnection` path from
`tcp.handleIncomingConnection`.

## 4. Address Priority (LAN vs WAN)

A peer record can hold up to 8 addresses
([Chapter 2.2](../discovery/kbucket.md)). `connectToPeerMulti` sorts a copy
by `network.addressPriority` (`src/net/transport/mod.zig`) and tries each in
turn, returning `error.AllAddressesFailed` if none works:

| Priority | Addresses |
| :--- | :--- |
| 0 | loopback (`127.0.0.0/8`, `::1`) |
| 1 | private / LAN (RFC 1918 and similar) |
| 2 | everything else |

Two devices on the same Wi-Fi therefore connect over the LAN even when the
DHT also knows a public address. `PeerInfo.getBestAddress` uses the same
order.

## 5. The Reaper

`runReaper` wakes every `reap_interval_ms = 10_000` and walks the pool:

*   **In use counts as active.** If `conn.isInUse()` (someone besides the
    manager holds a reference, or a stream is open), `last_active` is set to
    now.
*   **Closed** (`isClosed()`, for example after a TCP reset) or **idle**
    (`now - last_active > idle_timeout`, 5 minutes) connections are removed
    and retired: `close()`, join the handler thread, drop the manager's
    reference. Anyone else still holding the connection keeps it alive until
    they release it.

`last_active` is set when a connection is registered, when
`findConnectionLocked` hands it out, and by the reaper while it is in use.

## 6. Shutdown

`stop()` marks the manager as stopping (`addConnection` then returns
`error.ManagerStopping`), stops the LAN announcer, closes the listening
socket, joins the accept thread, waits for in-flight handshakes, retires every
pooled connection, joins the reaper and UPnP threads, and finally removes the
UPnP port mapping if one was made. Mappings are requested with an infinite
lease, so leaving one behind would keep the port forwarded.

## 7. Why This Matters

*   **Resource limits**: idle and dead connections don't pile up. A peer that
    connects and never speaks is cut off by the 10-second handshake timeout.
*   **Mobile**: idle sockets are closed after 5 minutes, so the radio can
    sleep.
*   **Roaming**: a device that changes address shows up as a new connection,
    and the old one is reaped.

---

**Next Chapters:**
*   [Chapter 1.5: Local Discovery (LAN announcements)](./mdns.md)
*   [Chapter 2: Discovery Overview](../discovery/overview.md)
