# Relay routing: how it should work (investigation, 2026-10-31)

A phone away from home couldn't reach any home device, although NomadFS has
relays ([Chapter 1.7](./relay.md)) and the swarm has a public node (doew).
This chapter records what was found, how the systems that solve this problem
for a living do it, and the plan to make NomadFS's routing as dependable.

## 1. What was wrong

Reproduced with `scripts/outside-test.sh`: a node on the public server, in a
network namespace that reaches only the server's public address (no VPN, no
private ranges) and that nothing can dial, joins the swarm like a phone on
mobile data.

| | Before | After the fix |
| :--- | :--- | :--- |
| Devices listed by the outside node | doew only, for 6 minutes | doew, Plex, Ridge and Poco within 10 s |
| Relayed connections set up | yes, to three home devices | yes |

The relays worked; the layer above didn't use them:

1. **The device list came from the routing table only**
   (`BlockManager.knownPeers`). A device reached through a relay never
   enters the routing table: its PING arrives with no address of its own,
   which is skipped so the relay's address isn't recorded as the device's.
   So the folder layer never asked it for its shares, and the swarm folder
   never synced with it.
2. **`BlockManager.connectTo` needed a routing-table entry** (`findPeer`,
   else a DHT lookup) before it would dial, so `shares()` and every other
   request to a relayed device failed with `ProviderUnreachable`, without
   trying the open relayed connection or a new relay.

Both are fixed: `knownPeers` adds every device with a connection, and
`connectTo` reuses an open connection, then falls back to the connection
manager's relay when the device has no address that answers.
`tests/cluster/relay_peers_test.zig` covers it.

Seen in the logs as well, and not explained by those two: the Pixel's own
connection to doew closed 7 to 42 seconds after it opened, over and over
(the outside node's never did). The phone's log is needed to say whether
the app, Android or the carrier closed it; the keepalive work below makes
it either not happen or recover within seconds.

## 2. How others do it

| | libp2p circuit relay v2 | Tailscale DERP | Syncthing relays |
| :--- | :--- | :--- | :--- |
| Unreachable node | makes a **reservation** on a relay and keeps the connection alive for it | keeps a connection to its **home DERP** server | **joins** a relay in permanent mode and waits for invitations |
| How others find the relay | it **advertises a circuit address** `/relay/p2p-circuit/p2p/me` | the coordination server tells peers each node's home DERP | its relay address is published with its other addresses |
| Dialing | dial the relay named in the address (`HOP CONNECT`), relay tells the target (`STOP CONNECT`) | **relay first**: every connection starts on DERP and upgrades to direct while it runs | ask the relay for a session, both join it |
| Keepalive | the reservation is refreshed before it expires | traffic on a timer; NAT state for UDP lasts ~30 s | ping at least every minute, or the relay drops it |
| Upgrading to direct | DCUtR hole punching | path discovery in parallel, best RTT wins | none (relay is a fallback) |
| Rules | no relaying over relayed connections; resource limits | end-to-end encryption, the relay sees only ciphertext | TLS inside; the relay sees ciphertext |

Four ideas are common to all three:

1. **The unreachable side acts first.** A node that can't be dialed keeps a
   standing connection to a relay, on purpose, kept alive, and the relay
   treats it as something not to prune.
2. **Others are told which relay.** The relay is part of the node's
   address. A dialer goes straight to it; it doesn't search.
3. **The relay is not a last resort tried after timeouts.** Tailscale starts
   on it; libp2p dials the circuit address next to the direct ones.
4. **Liveness is checked, not assumed.** Keepalives below the NAT's timeout
   in both directions, and a connection that misses them is closed and
   rebuilt at once.

## 3. NomadFS today, against those

| | NomadFS | Gap |
| :--- | :--- | :--- |
| Unreachable side | the 30 s maintenance loop redials remembered devices, which includes the public node | not deliberate: subject to the 30 s round, dial backoff (30 s up to 2 min) and the 5-minute idle reaper |
| Finding the relay | the dialer asks each connected device in turn (`dialThroughRelayOnce`) | no "reachable via R" anywhere; order is whatever `liveConnections` returns |
| When the relay is tried | after every direct address times out, one by one (3 s each); a device with 8 addresses costs 24 s | relay last, and slow to get to |
| Keepalive | none: no TCP keepalive, Yamux answers PING but never sends one | a connection killed by a carrier NAT looks open until a write fails |
| Relayed devices | not in the routing table, not remembered (`rememberPeers` saves the routing table) | second-class: fixed for listing and dialing (section 1), still not remembered |
| Negative caches | relay misses 60 s; dial backoff 30 s to 2 min | one failed attempt can hide a device for minutes |
| Rules | swarm members only, no chaining, 32 at once, end to end Noise | sound |

## 4. The plan

In order; each step is useful alone.

1. **Relayed devices are first-class** (done, section 1).
2. **Keepalive and fast failure.** Every connection idle for 15 s sends a
   Yamux PING; two missed (about 30 s) close it. Set `SO_KEEPALIVE` with a
   short `TCP_KEEPIDLE` too, for the cases where the process can't run
   (an app frozen in the background). A closed connection to a relay is
   redialed at once, not on the next 30 s round.
3. **Standing connections to relays.** A node keeps one connection to each
   device that announces the relay role (always-on with a public address:
   `relay = true`, or learned from `DIAL_BACK`). These aren't reaped as idle
   and aren't subject to dial backoff.
4. **"Reachable via R" in the addresses a node announces.** A node that
   can't be dialed (no `DIAL_BACK` success) adds `via <relay node ID>` for
   each relay it holds a connection to, in PING/PONG and in what others
   remember. A dialer asks that relay first, in parallel with the direct
   addresses, and only searches other connected devices when it has none.
5. **Direct and relay in parallel.** Dial all direct addresses at once with
   a short head start, and the advertised relay after ~500 ms
   (happy-eyeballs style); use whichever completes first. The 30 s check
   already moves a relayed connection to a direct one when it appears.
6. **Remember relayed devices**, with the relay they were reached through,
   so a restart away from home finds them again.
7. **Shorter negative caches for relays** (a failed relay attempt retried
   after 10 s, not 60 s), since the relay itself is up.

Not planned: hole punching (TCP simultaneous open is unreliable through
carrier NAT; relays already reach every case).

## 5. Done so far

| Step | Where | What it does |
| :--- | :--- | :--- |
| 1 | `BlockManager.knownPeers`, `connectTo` (0.3.16) | relayed devices listed and reachable |
| 2 | `yamux.Session.keepAlive`, `tcp.zig` `maintain` | PING after 15 s of silence; nothing received for 45 s closes the connection |
| 2 | `ConnectionManager.lost`, `Node.sleepUntilNextRound` | a closed connection starts the next maintenance round within seconds |
| 3 (partly) | `discovery.Node.anchors`, `Node.dialKnownPeers` | bootstrap peers and relays used are anchors: redialed at least every 10 s, rounds every 5 s while none answers, and when one comes back every device is retried at once |
| 6 | `KnownPeers.rememberReached`, `Node.rememberPeers` | relayed devices remembered without addresses and pinged each round, so their relayed connection isn't closed as idle |
| — | `devices.Directory.refreshAll` | every listed device is asked again (setting its relay up again), and stays listed through a 45 s gap |

Measured with `scripts/outside-test.sh` and a 75 s black hole on the outside
node's path (no reset, like a NAT dropping the mapping):

| | Before | After |
| :--- | :--- | :--- |
| Home devices listed at start | doew only | all within 10 s |
| Dead path noticed | never (no keepalive) | 45 s, listed until then |
| Path back → relay reconnected | 1 min 44 s | 7 s |
| Path back → every device listed | 1 min 54 s | 27 s |

Still to do: steps 4 (announce "reachable via R"), 5 (direct and relay in
parallel) and 7 (shorter relay negative caches outside the cut-off case).

## 6. Testing it

- `scripts/outside-test.sh` on the public node: the outside device must list
  every home device within one maintenance round, and keep listing them.
- Kill the outside node's connection to the relay (or the relay itself) and
  measure the time until the home devices are listed again.
- `tests/cluster/relay_peers_test.zig` and `tests/dht/relay_test.zig` in
  `zig build test`.
