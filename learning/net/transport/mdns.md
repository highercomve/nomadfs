# Chapter 1.5: Local Discovery (LAN Announcements)

Devices on the same network should find each other without configuration and
without the DHT. NomadFS does this with a small UDP multicast beacon in
`src/net/transport/mdns.zig`. The file and type are called `MDNS`, but the
protocol is **not** Multicast DNS or DNS-SD: there are no DNS records,
queries or service names. It reuses the mDNS multicast group and sends its
own announcement on its own port.

> Overview: [Learn: TCP, finding and reaching devices](https://nomadfs.foreachdeveloper.com/learn/tcp/#addresses).

## 1. Why a LAN Beacon?

*   **Speed and cost**: LAN transfers are much faster than going out through
    the internet, and use no data plan.
*   **Offline**: two devices on the same Wi-Fi find each other even when the
    internet connection is down.
*   **Zero config**: no `bootstrap_peers` needed at home.

## 2. The Wire Format

| | |
| :--- | :--- |
| Group | `224.0.0.251` (`MDNS_MULTICAST_ADDR`) |
| Port | UDP **5354** (`MDNS_PORT`), deliberately not 5353 |
| Interval | every **2 seconds** (`announce_interval` in `runLoop`) |
| IP version | IPv4 only |

Each announcement is a magic prefix followed by a small JSON-like object
(`broadcastAnnouncement`):

```
NMFS{"id":"<64 hex chars: node ID>","port":9000}
```

`id` is the sender's **node ID** (BLAKE2s-256 of its X25519 transport key),
and `port` is its TCP listening port (`network.port`).

## 3. The Discovery Loop

`MDNS.start()` opens two sockets on the calling thread: a receive socket
bound to `0.0.0.0:5354` with `SO_REUSEADDR`/`SO_REUSEPORT` (so several nodes
on one machine can share the port), joined to the group, with a 1-second
receive timeout; and a send socket with multicast loopback enabled. It then spawns `runLoop`, which:

1.  **Announces** every 2 seconds.
2.  **Receives** a datagram (up to 1 KiB). Thanks to the receive timeout,
    the loop keeps announcing even when nothing arrives.
3.  **Parses** it in `handlePacket`:
    *   anything without the `NMFS` prefix is ignored silently;
    *   the `id` must be exactly 64 hex characters, and `port` must be a
        non-zero number, or the packet is rejected (`error.InvalidFormat`);
    *   our own announcements (same node ID) are ignored.
4.  **Builds the address** from the datagram's *source IP* and the announced
    port, and calls the callback (`ConnectionManager.onMdnsDiscovery`, which
    forwards to the discovery handler).

In a node that handler is `discovery.Node.onDiscovery`
(`src/net/discovery/node.zig`). If the node ID isn't already in the routing
table, it dials the address with `connectToPeer(addr, swarm_key, peer_id)`
and sends a `PING`. The peer enters the routing table only after the `PONG`
([Chapter 2.4](../discovery/rpc.md)).

## 4. Security Considerations

The beacon is plaintext and unauthenticated. Anyone on the LAN can read a
node's ID and port, and anyone can send fake announcements. That is
acceptable because an announcement only suggests an address to try:

1.  The dial runs the full [Noise XXpsk3 handshake](./noise.md). Without the
    swarm key it fails.
2.  `connectToPeer` is given the announced node ID. If the handshake proves a
    different static key, the dial fails with `error.PeerIdMismatch`.
3.  Malformed packets are rejected before they reach the callback.

## 5. Configuration and Platforms

*   `enable_mdns = true` (the default) in `nomadfs.conf`.
    `ConnectionManager.listen` starts the beacon only when it is set.
*   **Windows**: not supported. The socket helpers are POSIX-only, so
    `start()` prints a message and leaves discovery off.
*   If the sockets can't be set up (for example, the port is taken), the
    beacon stays off and `start()` still succeeds.
*   `stop()` shuts the sockets down to unblock the worker, joins it, and only
    then closes the descriptors.

---

**Next Chapters:**
*   [Chapter 1.6: UPnP & DIAL_BACK](./nat.md)
