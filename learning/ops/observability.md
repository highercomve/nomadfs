# Chapter 8.3: Observability

NomadFS has no metrics endpoint and no stats command. What an operator can
see today is the process's stderr output and the status the app shows.

## 1. Logs

All diagnostics are `std.debug.print` calls, which write to **stderr**,
unbuffered and without levels, timestamps or structure. Run the node under
systemd (journald captures stderr) or redirect it (`2>> nomadfs.log`) and
rotate the file with `logrotate`; NomadFS does not rotate anything itself.

Lines worth recognising:

| Output | Source | Meaning |
| :--- | :--- | :--- |
| `NomadFS Node: <nick> (Storage: true)`, `Listening on port: …` | `src/main.zig` | Startup |
| `Node Initialized. Local ID: …` / `Device ID: …` | `src/main.zig` | Transport node ID and Ed25519 device ID (hex) |
| `Sharing '<name>' from <path> (indexing in the background)` | `src/node.zig` | A share was registered |
| `* Noise_XXpsk3 handshake start (Initiator)` … `* Noise Handshake complete` | `src/net/transport/noise.zig` | One line per handshake step |
| `* Noise Error at step 'Message 3 Decrypt (payload/psk verify)'` | `noise.zig` | The peer has a different swarm key |
| `… device identity: error.UntrustedDevice` / `TransportKeyMismatch` | `noise.zig`, `src/device/auth.zig` | Trust policy refused the peer |
| `Bootstrapping: Connecting to …`, `Retry n/5 …` | `src/node.zig` | Bootstrap dials |
| `mDNS: …` | `src/net/transport/mdns.zig` | LAN announcement errors |
| `UPnP …` | `src/net/transport/manager.zig`, `nat.zig` | Port mapping progress or failure |
| `Revocation sweep: …`, `Refused a swarm key rotation: …` | `src/net/discovery/node.zig` | Trust maintenance |
| `swarm: …`, `swarm backup: …` | `src/fs/swarm.zig` | Manifest save and backup problems |
| `fuse: …` | `src/fs/fuse.zig` | Mount request failures (e.g. a block that couldn't be fetched) |

The handshake lines are verbose by design (every connection prints several);
there is no switch to silence them.

## 2. Status the App Shows

The app (`nomadfs-gui`) reads state from the running node through its
commands (`nomadfs-gui/src/commands.zig`), for example:

- whether the node is running and its device ID (`nodeState`);
- reachable devices (`remoteDevices`) and trusted devices (`devicesList`);
- each share's scan state (`sharesLocal`);
- the swarm folder's entry count, peers synced and last sync time
  (`SwarmFolder.status`), and the backup counters
  (`swarmBackupStatus` → `SwarmFolder.backupStatus`: files, files copied,
  bytes, unreachable files, last round).

See [Chapter 7: The App](../app/gui.md).

## 3. Measuring traffic and speed

- **Wire counters.** `ConnectionManager.trafficTotals()` counts every byte read from and written to
  device sockets (Noise and Yamux framing included), as atomics in `src/net/transport/`. A device's
  About in the app shows them as *sent* and *received* (`NODE_INFO`).
- **`nomadfs --bench-read <swarm path> [--bench-cold] [--bench-wait S]`** runs a node with the
  normal config, waits for a swarm sync and a connection to the file's author, optionally empties the
  read cache, reads the file in 1 MiB reads through the normal path (read-ahead, fetcher), and prints
  `key=value` lines: bytes, seconds, MiB/s, wire bytes, the fetcher's counters, and per device the
  blocks and bytes it served and its measured rate.
- **`nomadfs --bench-idle S`** runs a node for S seconds and prints the wire bytes: what a device
  costs the network at rest.
- **`scripts/bench-devices.sh <path> [reader…]`** stops each reader's node (a systemd service over
  SSH, the desktop app, the phone app over adb), runs the benchmark with the same identity, starts
  the node again, and prints a table; `WARM=<device>` reads the file there first, so it becomes a
  second holder; `IDLE=60` measures idle traffic instead. Results are kept under `.agents/bench/`.

## 4. `src/metrics.zig` (not wired in)

`src/metrics.zig` defines a `MetricsCollector` (a fixed ring of 10,000
samples: `incrementCounter`, `recordGauge`, `recordHistogram`, `snapshot`)
and a `Span` type for traces. It is exported as `nomadfs.metrics` and has
tests, but **no code records anything into it** and nothing exports it.

Not implemented yet:

- an HTTP `/metrics` endpoint or any metrics export;
- a `nomadfs stats` command;
- log levels or structured logging.

The metric names listed in older versions of this chapter
(`transport.bytes_sent`, `dht.peers_count`, …) are not emitted anywhere.

---

**Next:** [Chapter 8.4: Performance Notes](./performance.md) ·
[Back to the Internals Book](../README.md)
