# Chapter 1.6: UPnP & DIAL_BACK (NAT)

Most devices sit behind a router that does **Network Address Translation
(NAT)**. A device behind NAT can dial out, but peers outside can't dial in,
because its address (for example `192.168.1.5`) isn't routable from the
internet. NomadFS has two small tools for this: a **UPnP** client that asks
the router to forward the port, and a **`DIAL_BACK`** request that asks a
peer to connect back. Neither guarantees reachability, and there is no relay
yet (see section 4).

## 1. UPnP Port Mapping (`src/net/transport/nat.zig`)

`ConnectionManager.listen` starts a background thread when
`upnp_enabled = true` (the default). The thread runs three steps on the
`nat.UPnP` client. Each HTTP step is bounded by `http_timeout_ms = 5_000`, so
a dead gateway can't block shutdown.

1.  **`discoverGateway()` (SSDP)**: sends an `M-SEARCH` for
    `urn:schemas-upnp-org:device:InternetGatewayDevice:1` to
    `239.255.255.250:1900` and reads replies for up to 2 seconds. The
    `LOCATION:` header gives the device description URL, which is fetched
    with `GET` to find the `WANIPConnection:1` control URL.
2.  **`getLocalIP()`**: "connects" a UDP socket to the gateway and reads the
    local address the kernel picked. This is the address the mapping should
    point at.
3.  **`mapPort(port, "TCP", local_ip)` (SOAP `AddPortMapping`)**: asks the
    router to forward external TCP `port` to the same port on this device,
    with description `NomadFS` and `NewLeaseDuration` 0 (no expiry). On
    success `mapped_port` is recorded.

Because the lease never expires, `ConnectionManager.stop()` sends
`DeletePortMapping` for `mapped_port`. Otherwise the router would keep
forwarding the port after the node exits.

Failures (no gateway, UPnP disabled on the router, `getLocalIP` on Windows)
are logged and ignored; the node keeps running without a mapping.

## 2. `DIAL_BACK` (a minimal AutoNAT)

A router that accepted a mapping may still not be reachable (carrier-grade
NAT, ISP firewalls, double NAT). `DIAL_BACK` is a request to check.

### The flow
1.  `Node.connectBootstrapPeer` (`src/root.zig`) connects to each configured
    bootstrap peer and sends a `PING`.
2.  It then calls `discovery.Node.checkReachability(conn)`, which opens a
    stream and sends **`DIAL_BACK { port }`** with this node's listening port.
    It doesn't wait for a reply.
3.  The peer (`handleDialBack`) takes the IP it sees the request coming from,
    sets the announced port, and calls
    `connectToPeer(address, swarm_key, sender_node_id)`. It always dials the
    *authenticated* sender, never an ID from the payload. On success it sends
    a `PING` over that connection.
4.  The requester's `handlePing` sets `is_public = true` when it receives an
    incoming `PING`.

`DIAL_BACK` is sent **once per bootstrap peer**, when it connects. Nothing
repeats it later, for example when the network changes.

### What the result is used for
Nothing, today. `discovery.Node.is_public` is set by **any** incoming `PING`,
not only by a dial-back, and it is only printed when the serve loop exits.
There are no "DHT server" and "DHT client" roles: every node serves every RPC
and joins other nodes' routing tables the same way.

### A caveat
`connectToPeer` first looks in the pool for a connection to the expected node
ID (see [Chapter 1.4](./management.md#3-connection-pooling)). The connection
the `DIAL_BACK` arrived on is pooled on both sides, so the dial-back usually
*reuses* it instead of opening a new TCP connection. The `PING` that follows
then proves nothing about whether the port is reachable from outside.

## 3. What Happens Without Reachability

A node that can't be reached can still dial out. Every connection is
symmetric once open: both sides open Yamux streams and serve RPCs, so a phone
behind NAT that dials a home server can be asked for blocks over that same
connection. Two devices that are both unreachable and on different networks
can't connect today.

## 4. Not implemented yet

From [ROADMAP.md](../../../ROADMAP.md), Phase 7 ("Persistent Roaming & NAT
Splicing Relay"):

*   an always-on node that **relays** encrypted streams between two peers
    that can't reach each other;
*   Yamux `PING` **keep-alives** to hold NAT mappings open;
*   using reachability to change how a node takes part in the DHT.

---

**Next Chapters:**
*   [Chapter 2: Discovery Overview](../discovery/overview.md)
