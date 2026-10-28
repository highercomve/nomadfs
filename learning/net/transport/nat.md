# Chapter 1.6: UPnP & DIAL_BACK (NAT)

Most devices sit behind a router that does **Network Address Translation
(NAT)**. A device behind NAT can dial out, but peers outside can't dial in,
because its address (for example `192.168.1.5`) isn't routable from the
internet. NomadFS has two small tools for this: a **UPnP** client that asks
the router to forward the port, and a **`DIAL_BACK`** request that asks a
peer to connect back. Neither guarantees reachability; when no address
answers, another device can carry the connection
([Chapter 1.7](./relay.md)).

## 1. UPnP Port Mapping (`src/net/transport/nat.zig`)

`ConnectionManager.listen` starts a background thread when `upnp_enabled = true`. It is **off by default**: opening a port on the router publishes the listener to the Internet, and the swarm key is the only gate (see [Security Model](../../security/model.md)). The thread discovers the gateway, maps the port, and then keeps the mapping alive until the node stops.

1. **`discoverGateway()` (SSDP)**: sends `M-SEARCH` for `InternetGatewayDevice:1` and `:2` to `239.255.255.250:1900` and listens for 3 seconds. A reply is accepted only if it comes from an address on one of this device's own subnets (preferably the default gateway), its `ST` matches, and its `LOCATION` is an `http://` URL whose host is the sender itself. Anything else is ignored.
2. **Description and control URL**: the thread fetches the description from that host only and takes the `controlURL` of the `WANIPConnection:1/2` or `WANPPPConnection:1` service. URLs containing control characters or naming another host are rejected.
3. **`getLocalIP()`**: unchanged.
4. **`AddPortMapping`** with a **3600-second lease**, renewed every 30 minutes. Some older routers answer error 725 ("only permanent leases"); then NomadFS retries with lease 0 and logs a warning. After mapping, `GetExternalIPAddress` is checked: a private or carrier-grade address means no mapping can help and it is removed.

`ConnectionManager.stop()` sends `DeletePortMapping` for `mapped_port` using the cached control URL. If the process is killed instead, a finite lease lets the router drop the rule within an hour (not on the 725 fallback, where the entry stays until the router forgets it).

Failures (no gateway, UPnP disabled on the router, `getLocalIP` on Windows)
are logged and ignored; the node keeps running without a mapping.

## 2. `DIAL_BACK` (a minimal AutoNAT)

A router that accepted a mapping may still not be reachable (carrier-grade
NAT, ISP firewalls, double NAT). `DIAL_BACK` is a request to check.

### The flow
1.  `Node.connectBootstrapPeer` (`src/root.zig`) connects to each configured
    bootstrap peer and sends a `PING` coherence check.
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

*   Yamux `PING` **keep-alives** to hold NAT mappings open;
*   using reachability to change how a node takes part in the DHT.

---

**Next Chapters:**
*   [Chapter 2: Discovery Overview](../discovery/overview.md)
