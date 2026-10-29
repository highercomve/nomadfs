# Chapter 9: API Reference (Zig)

NomadFS is a Zig module (`src/root.zig`, imported as `nomadfs`). The CLI
(`src/main.zig`), the C ABI library ([Chapter 10](../mobile/api.md)) and
the app (`nomadfs-gui`, which imports the module directly) all build on it.
This chapter lists the entry points that exist today, with their real
signatures. There is no file-path API (`File.read`/`File.write`), no
`delete`, and no bloom filter.

Top-level namespaces exported by `src/root.zig`:

| Name | Contents |
| :--- | :--- |
| `config` | `Config`, `parseConfig`, `parseConfigText`, `findAndParseConfig` |
| `net` | `transport` (connection manager, Noise, Yamux, TCP, mDNS, NAT), `discovery` (DHT node, RPC), `id` |
| `storage` | `block`, `engine`, `chunker`, `dag` (`codec`, `builder`, `walk`, `diff`) |
| `cluster` | `BlockManager`, `repair`, `quorum`, `ring`, `vectors` |
| `fs` | `scan`, `shares`, `tree`, `remote`, `filestore`, `manifest`, `swarm`, `fuse` (desktop Linux only) |
| `device` | `identity`, `pairing`, `trust`, `invite`, `rotation`, `auth`, `paths`, `qr` |
| `mobile_api` | the exported C functions |
| `metrics` | an unwired metrics collector ([Chapter 8.3](../ops/observability.md)) |
| `Node` | the orchestrator below |

## 1. `Node` (`src/root.zig`)

```zig
pub const Node = struct {
    connection_manager: *ConnectionManager,
    store: ?*storage.engine.StorageEngine,   // null when storage is disabled
    discovery_node: *DiscoveryNode,
    block_manager: *cluster.BlockManager,
    device_identity: device.identity.Identity,
    trust_store: *device.trust.Store,
    shares: ?*fs.ShareIndex,                 // with storage only
    swarm: ?*fs.SwarmFolder,                 // with storage only
    // … ring, device_paths, bootstrap thread state

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Node;
    pub fn deinit(self: *Node) void;
    pub fn bootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) !void;
    pub fn run(self: *Node, running: *std.atomic.Value(bool), cfg: config.Config) !void;
    pub fn rotateSwarmKey(self: *Node, allocator: std.mem.Allocator, new_key: [32]u8, epoch: u64) ![]Delivery;
};
```

- `init` wires everything (order in [Chapter 8.1](../ops/deployment.md#3-what-starts-when-the-node-runs)),
  registers each configured share and starts the share rescan and swarm sync
  threads. It does not listen yet.
- `bootstrap` starts a thread that dials the given peers, then does the
  self-lookup and the 60 s maintenance loop (bucket refresh, revocation
  sweep). Calling it again restarts that thread.
- `run` opens the TCP listener (plus LAN announcements and UPnP when enabled)
  and blocks until `running` is false.
- `rotateSwarmKey` sends a signed new key to every reachable trusted device
  and returns one `Delivery { name, status }` per device, with status
  `delivered`, `refused`, `not_paired`, `offline` or `failed`. The caller owns
  the names and the slice. See [Chapter 6.3](../security/invites.md#2-swarm-key-rotation).

## 2. Blocks and Storage

### `storage.block.Block`

```zig
pub const Block = struct {
    cid: [32]u8,        // SHA-256 of `data`
    data: []const u8,   // the encoded block: tag byte + payload
    pub fn new(data: []const u8) Block; // hashes data
};
```

A block has no `links` field: links live inside the encoded bytes of parent
and dir blocks (`storage.dag.codec`, see [Merkle DAGs](../storage/dag.md)).

### `storage.engine.StorageEngine`

```zig
pub fn init(allocator, path: []const u8) !StorageEngine;  // creates the directory; "~" expanded
pub fn put(self, block: Block) !void;                     // error.HashMismatch if cid ≠ SHA-256(data)
pub fn has(self, cid: []const u8) bool;
pub fn get(self, cid: []const u8, allocator) !?Block;     // null if absent; error.CorruptBlock if bytes don't match
pub fn deinit(self) void;
external: ?External = null;  // fallback source for missing blocks (the filestore)
```

`put` is idempotent (an existing block is not rewritten) and writes
`<hex>.tmp` then renames it. There is no delete and no garbage collection.
Details: [The Disk Engine](../storage/engine.md).

### `storage.dag`

- `DagBuilder{ .allocator, .store, .layout = .Balanced }` (`layout` has no
  default; every caller uses `.Balanced`; optional `.leaf_sink`)
  `.build(reader) ![]const u8` chunks any reader with FastCDC and returns the
  caller-owned root CID. With `leaf_sink` set, leaves are reported as
  `(cid, offset, len)` instead of stored (shared folders).
- `walk.readFile(allocator, store, root, writer, ReadOptions{ .max_bytes })`
  writes a whole file from local blocks; `walk.isComplete` checks every block
  is present; `walk.collectReachable` lists them.
- `codec.decode(bytes) !View` validates and decodes a leaf, parent or dir
  block; `codec.encodeDir` builds a dir block.

## 3. The distribution layer (`src/cluster/`)

Every read and copy of another device's blocks goes through here
([Chapter 4](../cluster/overview.md)).

```zig
// cluster.Fetcher (fetcher.zig), BlockManager.fetcher
pub fn fetch(self, root: *const Cid, cid: *const Cid, holders: []const NodeID, allocator) ![]u8;
pub fn snapshot(self, out: []PeerState) []PeerState;  // per device: rate, in flight, blocks, bytes
pub fn totals(self) Stats;                             // local, fetched, not_found, failed

// cluster.Holders (holders.zig), BlockManager.holders
pub fn noteKeeps(self, holder: NodeID, origin: NodeID) void;
pub fn forOrigin(self, origin: NodeID, out: *[8]NodeID) []NodeID;  // a share's files
pub fn forSwarm(self, author: NodeID, out: *[8]NodeID) []NodeID;   // a swarm file

// cluster.placement (placement.zig)
pub fn replicaHolders(root: *const Cid, author: NodeID, copies: u8, members: []const NodeID, out: []NodeID) []NodeID;
pub fn candidates(allocator, trust, policy, self_node: NodeID, self_device: NodeID) ![]NodeID;

// cluster.keeper (keeper.zig)
pub fn copy(allocator, fetcher, store, root: Cid, hints: []const NodeID, keep_going: *const std.atomic.Value(bool)) !Copied;
Keeper.register(provider: Provider) !void;  // fs says what to keep: wantsFn, doneFn
Keeper.wake(self) void;

// device.policy (src/device/policy.zig), Node.policy
pub fn copies(self) u8;
pub fn acceptsCopies(self, device: NodeID) bool;
pub fn setCopies(self, identity, trust, n: u8, now: u64) !Outcome;  // signs, applies, saves
pub fn apply(self, r: Record, trust, self_device: NodeID, now: u64) !Outcome;
```

### `cluster.BlockManager` (`src/cluster/block_manager.zig`)

Owns the fetcher and the holders, and keeps a file-level put/get on top of the
store and the DHT for the C ABI's `nomadfs_put_file`/`nomadfs_get_file`.

```zig
pub fn put(self, reader: anytype) ![]const u8;                 // root CID, caller-owned
pub fn get(self, root: []const u8, writer: anytype, options: walk.ReadOptions) !u64;
pub fn fetch(self, root: []const u8) !void;                    // copy missing blocks only
pub fn announce(self, root: []const u8) !void;                 // ADD_PROVIDER to closest peers
pub fn replicate(self, root: []const u8, fanout: usize) !usize; // PUT_BLOCK the DAG
pub fn connectTo(self, peer_id: NodeID) !network.Connection;   // routing table, else lookup
```

- `put` builds the DAG into the local store, then `announce` (skipped when
  `write_quorum = 0`; with no acknowledgements it returns
  `error.QuorumNotReached`, blocks stay local, calling `put` again retries),
  then, if `replicas > 0`, `replicate` synchronously to the Kademlia-closest
  peers of the root CID. Replication failures never fail a `put`.
- `get` returns `error.StorageDisabled` without a store; otherwise fetches
  missing blocks (`fetch`: provider records first, then the closest peers),
  then writes the file. Fetch errors include `NoProvider`, `BlockNotFound`,
  `ProviderUnreachable`.

See [Cluster overview](../cluster/overview.md).

## 4. Shared Folders and the Swarm Folder (`fs`)

```zig
// fs.ShareIndex (src/fs/shares.zig)
pub fn add(self, name: []const u8, path: []const u8) !void;      // register + scan now
pub fn register(self, name: []const u8, path: []const u8) !void; // scanned by the rescan thread
pub fn remove(self, name: []const u8) bool;
pub fn snapshot(self, allocator) ![]Share;                       // name, path, root (null until scanned), size, files, scanned_at
pub fn listing(self, allocator) ![]u8;                           // the GET_SHARES dir block

// fs.tree (src/fs/tree.zig): read any tree through a Loader
pub fn listDir(allocator, loader: Loader, cid: *const Cid) !Listing;
pub fn resolve(allocator, loader: Loader, root: Cid, path: []const u8) !Entry;
pub fn readAt(allocator, loader: Loader, root: Cid, offset: u64, dest: []u8) !usize;

// fs.remote (src/fs/remote.zig): name the holders, the fetcher picks per block
pub fn readShareAt(allocator, block_manager, store, read_ahead, peer: NodeID, root: Cid, offset: u64, dest: []u8) !usize;
Remote{ .block_manager, .store, .peer, .root }.loader()   // one holder
MultiRemote{ .block_manager, .store, .peers, .root }.loader()
Remote.shares(allocator) !Shares                   // GET_SHARES: nickname + listing; notes who keeps whose folders

// fs.SwarmFolder (src/fs/swarm.zig)
pub fn addFile(self, dir: []const u8, name: []const u8, local_path: []const u8) !void;
pub fn makeDir(self, dir: []const u8, name: []const u8) !void;
pub fn remove(self, path: []const u8) !void;
pub fn rename(self, path: []const u8, new_name: []const u8) !void;
pub fn move(self, path: []const u8, new_path: []const u8, options: MoveOptions) !void;
pub fn list(self, arena, dir: []const u8) ![]Item;
pub fn readAt(self, allocator, cid: [32]u8, author: [32]u8, offset: u64, dest: []u8) !usize;
pub fn syncNow(self) !usize;                    // GET_SWARM from every known peer, merge
pub fn setBackup(self, on: bool) !void;
pub fn status(self) Status;  pub fn backupStatus(self) BackupStatus;

// fs.fuse.Mount (src/fs/fuse.zig, desktop Linux only)
pub fn init(allocator, block_manager, store) !Mount;   // set .swarm to expose <mount>/Swarm
pub fn serve(self, mountpoint: []const u8) !void;      // blocks until unmounted
pub fn unmount(mountpoint: [:0]const u8) void;         // fusermount3 -u -z
```

Explanations: [Shared folders](../fs/shares.md), [The swarm folder](../fs/swarm.md),
[The FUSE mount](../fs/fuse.md).

## 5. Devices (`device`)

| Function | Purpose |
| :--- | :--- |
| `identity.Identity.loadOrCreate(path)`, `.deviceId()`, `.fingerprint()`, `.sign(msg)`, `Identity.verify(pub, msg, sig)` | Ed25519 device identity |
| `pairing.Ticket.init(identity, transport_pub, nickname, addresses, expires_at)`, `.toUri(buf)`, `Ticket.parseAt(uri, now)` | Signed pairing tickets |
| `trust.Store.load(allocator, path, seed)`, `.trustTicket(ticket, now)`, `.revokeDevice(id, signer, at)`, `.resolve(query)`, `.list()`, `.save()` | Trust store |
| `invite.Host.start(...)`, `Host.code/status/joinedTicket/destroy`, `invite.join(allocator, code, my_ticket)` | One-time invites |
| `rotation.message(epoch, key)`, `rotation.verify(...)` | Swarm-key rotation |
| `paths.Paths.resolve(allocator, key_path)` | Where `device.key` and `trust.store` live |

See [Chapter 6](../security/model.md).

## 6. Errors Callers See Most

| Error | From |
| :--- | :--- |
| `MissingRequiredField`, `InvalidSwarmKey`, `UnsupportedTransport`, `ReplicasOutOfRange` | `config` |
| `StorageDisabled`, `QuorumNotReached`, `NoProvider`, `ProviderUnreachable` | `BlockManager` |
| `HashMismatch`, `CorruptBlock` | `StorageEngine` |
| `BlockNotFound`, `IsDirectory`, `NotADirectory`, `DagTooDeep` | `fs.tree`, `fs.remote` |
| `UntrustedDevice`, `TransportKeyMismatch`, `InvalidDeviceHello` | handshake (`device.auth`) |
| `ExpiredTicket`, `TrustStoreFull`, `BadStoreSignature` | `device.pairing`, `device.trust` |

---

**Next:** [Chapter 10: Mobile C ABI & Bindings](../mobile/api.md) ·
[Back to the Internals Book](../README.md)
