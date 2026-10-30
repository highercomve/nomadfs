//! The running node: wires storage, folders, devices, the cluster and the
//! network together, owns their lifecycles, and is the service API the CLI,
//! the app and the mobile API call (directly or through settings.zig).
const std = @import("std");
const config = @import("config.zig");
const net = @import("net/mod.zig");
const storage = @import("storage/mod.zig");
const device = @import("device/mod.zig");
const fs = @import("fs/mod.zig");

// A manifest the folder keeps must fit in a SWARM reply.
comptime {
    std.debug.assert(fs.manifest.max_bytes <= net.discovery.rpc.max_swarm_len);
}
const cluster = @import("cluster/mod.zig");
const sync = @import("sync.zig");
const node_info = @import("node_info.zig");
const version = node_info.version;
const nowSeconds = node_info.nowSeconds;

const ConnectionManager = net.transport.manager.ConnectionManager;
const DiscoveryNode = net.discovery.Node;
const HashRing = cluster.ring.HashRing;

pub const Node = struct {
    allocator: std.mem.Allocator,
    connection_manager: *ConnectionManager,
    store: ?*storage.engine.StorageEngine,
    discovery_node: *DiscoveryNode,
    block_manager: *cluster.BlockManager,
    ring: *HashRing,
    device_paths: device.paths.Paths,
    /// device/paths.zig lockNode: held until deinit's end.
    lock: std.Io.File,
    device_identity: device.identity.Identity,
    trust_store: *device.trust.Store,
    /// Folders this device shares; null without block storage.
    shares: ?*fs.ShareIndex,
    /// Keeps members' folders marked for backup on a swarm backup device.
    folder_backup: ?*fs.FolderBackup = null,
    /// The swarm-wide settings every device agrees on (copies, who accepts).
    policy: *device.policy.Policy,
    /// This device's membership: tickets, invites, trusting and revoking,
    /// the one service every front end uses (device/membership.zig).
    membership: *device.membership.Membership,
    membership_nickname: []u8,
    /// Copies what this device keeps (cluster/keeper.zig); null without a store.
    keeper: ?*cluster.keeper.Keeper = null,
    /// The swarm-wide folder every device reads and writes; null without
    /// block storage.
    swarm: ?*fs.SwarmFolder,
    /// Fetches ahead of reads of other devices' files (the mount, the app's
    /// previews, the swarm folder); null without block storage.
    read_ahead: ?*fs.ReadAhead,
    bootstrap_thread: ?std.Thread = null,
    /// Sorts blocks stored before the read cache existed, once (sortLegacyCache).
    cache_thread: ?std.Thread = null,
    cache_running: std.atomic.Value(bool) = .init(false),
    bootstrap_running: *std.atomic.Value(bool),
    /// Devices met before, with all their addresses; re-dialed to rejoin
    /// the swarm from any network (Tailscale away from home). Used only by
    /// the bootstrap thread.
    known_peers: *net.discovery.known_peers.KnownPeers,
    /// Answers GET_NODE_INFO.
    info_provider: *InfoProvider,
    /// When to try an unreachable known device again (ms), and how many
    /// tries failed in a row. Bootstrap thread only.
    redial: std.AutoHashMapUnmanaged(net.id.NodeID, Redial) = .empty,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Node {
        // First: nothing is opened or written while another node runs here.
        const lock = try device.paths.lockNode(allocator, cfg.node.key_path);
        errdefer lock.close(std.Io.Threaded.global_single_threaded.io());
        const connection_manager = try allocator.create(ConnectionManager);
        errdefer allocator.destroy(connection_manager);
        connection_manager.* = try ConnectionManager.init(allocator, cfg.network.transport, cfg.node.key_path);
        errdefer connection_manager.deinit();
        var store: ?*storage.engine.StorageEngine = null;
        if (cfg.storage.enabled) {
            const s = try allocator.create(storage.engine.StorageEngine);
            errdefer allocator.destroy(s);
            s.* = try storage.engine.StorageEngine.init(allocator, cfg.storage.storage_path);
            store = s;
        }
        errdefer if (store) |s| {
            s.deinit();
            allocator.destroy(s);
        };
        if (store) |s| if (cfg.storage.quota_mb > 0) {
            try s.setQuota(cfg.storage.quota_mb * 1024 * 1024);
        };
        if (store) |s| try s.setCacheLimit(if (cfg.storage.cache_mb == 0) null else cfg.storage.cache_mb * 1024 * 1024);

        const discovery_node = try allocator.create(DiscoveryNode);
        discovery_node.* = DiscoveryNode.init(
            allocator,
            connection_manager,
            cfg.node.swarm_key,
        );
        errdefer {
            discovery_node.deinit();
            allocator.destroy(discovery_node);
        }

        // Serve our blocks to peers repairing from us.
        discovery_node.block_store = store;
        discovery_node.nickname = cfg.node.nickname;
        discovery_node.swarm_epoch = cfg.node.swarm_epoch;
        // What every PING and PONG says about this device (rpc.Roles).
        discovery_node.setRole(net.discovery.rpc.Roles.swarm_backup, cfg.storage.swarm_backup);
        discovery_node.setRole(net.discovery.rpc.Roles.metered, !net.local_addrs.onUnmeteredNetwork());
        discovery_node.setRole(net.discovery.rpc.Roles.accepts_copies, cfg.storage.accept_copies);

        var shares: ?*fs.ShareIndex = null;
        if (store) |s| {
            const index = try fs.ShareIndex.create(allocator, std.Io.Threaded.global_single_threaded.io(), s);
            shares = index;
            discovery_node.share_source = index.source();
        }
        errdefer if (shares) |index| index.destroy();
        if (shares) |index| {
            // A folder that cannot be read is reported, not fatal: the node
            // still serves everything else.
            for (cfg.shares) |share| {
                std.debug.print("Sharing '{s}' from {s} (indexing in the background)\n", .{ share.name, share.path });
                index.register(share.name, share.path) catch |err| {
                    std.debug.print("Share '{s}' unavailable: {any}\n", .{ share.name, err });
                };
            }
            if (cfg.shares.len > 0) try index.start();
            for (cfg.backup_shares) |name| try index.setBackup(name, true);
        }

        // Register DHT serve loop for new connections
        connection_manager.setConnectionHandler(discovery_node, DiscoveryNode.serve);
        connection_manager.setDiscoveryHandler(discovery_node, DiscoveryNode.onDiscovery);

        const block_manager = try cluster.BlockManager.init(allocator, .{
            .network = connection_manager,
            .dht = discovery_node,
            .storage = store,
            .quorum = .{ .W = cfg.storage.write_quorum },
        });
        errdefer block_manager.deinit();

        // Read-ahead comes before the swarm folder, which points at it: the
        // errdefers run in reverse, so the folder is destroyed first.
        var read_ahead: ?*fs.ReadAhead = null;
        if (store) |s| {
            read_ahead = try fs.ReadAhead.create(allocator, block_manager, s);
        }
        errdefer if (read_ahead) |ra| ra.destroy();

        var swarm: ?*fs.SwarmFolder = null;
        if (store) |s| {
            const manifest_path = try std.fmt.allocPrint(allocator, "{s}.swarm.json", .{cfg.storage.storage_path});
            defer allocator.free(manifest_path);
            const folder = try fs.SwarmFolder.create(allocator, std.Io.Threaded.global_single_threaded.io(), s, connection_manager.node_id, cfg.node.nickname, manifest_path);
            // Set before start(): the sync thread reads it.
            folder.read_ahead = read_ahead;
            discovery_node.swarm_source = folder.source();
            folder.start(block_manager) catch |err| std.debug.print("swarm: sync thread not started: {any}\n", .{err});
            if (cfg.storage.swarm_backup) folder.setBackup(true) catch |err| std.debug.print("swarm backup: not started: {any}\n", .{err});
            swarm = folder;
        }
        errdefer if (swarm) |f| f.destroy();

        const ring = try allocator.create(HashRing);
        ring.* = HashRing.init(allocator);
        errdefer {
            ring.deinit();
            allocator.destroy(ring);
        }

        // If storage is enabled, add ourselves to the ring
        if (cfg.storage.enabled) {
            try ring.addNode(connection_manager.node_id, 10);
        }

        var device_paths = try device.paths.Paths.resolve(allocator, cfg.node.key_path);
        errdefer device_paths.deinit(allocator);
        const device_identity = try device.identity.Identity.loadOrCreate(device_paths.identity);
        // Heap allocated so the authenticator's pointer stays valid after the
        // Node value is copied out of init().
        const trust_store = try allocator.create(device.trust.Store);
        errdefer allocator.destroy(trust_store);
        trust_store.* = try device.trust.Store.load(allocator, device_paths.trust, device_identity.seed());
        errdefer trust_store.deinit();
        const known_peers = try allocator.create(net.discovery.known_peers.KnownPeers);
        errdefer allocator.destroy(known_peers);
        known_peers.* = try net.discovery.known_peers.KnownPeers.load(allocator, std.Io.Threaded.global_single_threaded.io(), device_paths.peers);
        errdefer known_peers.deinit();

        // Revocations are signed with the device identity and recorded in
        // the same trust store the handshake policy reads.
        discovery_node.trust_store = trust_store;
        // A revoked device stops being a holder too (cluster/holders.zig).
        // Every revocation, from a peer, this device or another process on
        // this config (the disk merge), has the same effect: membershipRevoked.
        discovery_node.revocation_sink = .{ .ctx = block_manager, .revokedFn = membershipRevoked };
        trust_store.revoked_hook = .{ .ctx = block_manager, .revokedFn = membershipRevoked };

        // A swarm backup device keeps the members' folders marked for
        // backup too (fs/backup.zig); the thread starts with the listener.
        var folder_backup: ?*fs.FolderBackup = null;
        if (store) |s| if (shares) |index| if (swarm) |folder| {
            const state_path = try std.fmt.allocPrint(allocator, "{s}.backups", .{cfg.storage.storage_path});
            defer allocator.free(state_path);
            folder_backup = try fs.FolderBackup.create(allocator, std.Io.Threaded.global_single_threaded.io(), s, index, trust_store, block_manager, &folder.backup_enabled, state_path);
        };
        errdefer if (folder_backup) |b| b.destroy();
        discovery_node.device_identity = device_identity;

        const policy_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(device_paths.trust) orelse ".", "swarm.policy" });
        defer allocator.free(policy_path);
        const policy = try device.policy.Policy.load(allocator, policy_path);
        errdefer policy.destroy();

        // The keeper copies what the swarm folder says this device keeps;
        // its thread starts with the listener.
        var keeper: ?*cluster.keeper.Keeper = null;
        if (store) |s| if (block_manager.fetcher != null) {
            const k = try allocator.create(cluster.keeper.Keeper);
            k.* = cluster.keeper.Keeper.init(allocator, &block_manager.fetcher.?, s);
            keeper = k;
            if (swarm) |folder| {
                folder.placement = .{ .trust = trust_store, .policy = policy, .self_device = device_identity.deviceId() };
                folder.keeper = k;
                try k.register(folder.keeperProvider());
            }
        };
        errdefer if (keeper) |k| allocator.destroy(k);
        discovery_node.policy = policy;

        const membership_nickname = try allocator.dupe(u8, cfg.node.nickname);
        errdefer allocator.free(membership_nickname);
        const membership = try allocator.create(device.membership.Membership);
        errdefer allocator.destroy(membership);
        membership.* = .{
            .allocator = allocator,
            .identity = device_identity,
            .transport_key = connection_manager.identity_key.public_key,
            .nickname = membership_nickname,
            .node_port = cfg.network.port,
            .swarm_key = device.membership.Membership.swarmKey(cfg.node.swarm_key),
            .trust = trust_store,
            .hooks = .{ .ctx = block_manager, .trustedFn = membershipTrusted, .revokedFn = membershipRevoked },
        };
        if (keeper) |k| discovery_node.on_policy_change = .{ .ctx = k, .func = wakeKeeper };

        // This device's say in the swarm's policy: whether it accepts copies
        // (signed again only when it changed), and --copies.
        _ = policy.setAccepts(device_identity, trust_store, cfg.storage.accept_copies, nowSeconds()) catch |err| std.debug.print("policy: accept_copies not signed: {any}\n", .{err});
        if (cfg.storage.set_copies) |n| _ = policy.setCopies(device_identity, trust_store, n, nowSeconds()) catch |err| std.debug.print("policy: copies not set: {any}\n", .{err});

        const info_provider = try allocator.create(InfoProvider);
        errdefer allocator.destroy(info_provider);
        info_provider.* = .{
            .store = store,
            .storage_path = cfg.storage.storage_path,
            .shares = shares,
            .swarm = swarm,
            .trust = trust_store,
            .manager = connection_manager,
            .block_manager = block_manager,
            .started_at = node_info.nowSeconds(),
        };
        info_provider.storage_path = try allocator.dupe(u8, cfg.storage.storage_path);
        errdefer allocator.free(info_provider.storage_path);
        discovery_node.info_source = .{ .ctx = info_provider, .infoFn = InfoProvider.infoErased };

        connection_manager.setDeviceAuthenticator(.{
            .identity = device_identity,
            .trust = trust_store,
            .require_trusted = cfg.security.require_trusted_devices,
        });

        const bootstrap_running = try allocator.create(std.atomic.Value(bool));
        errdefer allocator.destroy(bootstrap_running);
        bootstrap_running.* = std.atomic.Value(bool).init(true);

        // Start only after all fallible allocations: error cleanup cannot
        // leave manager threads accessing resources already destroyed.
        try connection_manager.start();

        // Devices none of whose addresses answer are reached through
        // another device (net/transport/relay.zig). Last: nothing fails
        // after this, so the manager never outlives the node it points to.
        discovery_node.enableRelay();

        return Node{
            .allocator = allocator,
            .connection_manager = connection_manager,
            .store = store,
            .discovery_node = discovery_node,
            .block_manager = block_manager,
            .ring = ring,
            .device_paths = device_paths,
            .device_identity = device_identity,
            .trust_store = trust_store,
            .known_peers = known_peers,
            .info_provider = info_provider,
            .shares = shares,
            .swarm = swarm,
            .read_ahead = read_ahead,
            .folder_backup = folder_backup,
            .policy = policy,
            .membership = membership,
            .membership_nickname = membership_nickname,
            .keeper = keeper,
            .bootstrap_running = bootstrap_running,
            .bootstrap_thread = null,
            .lock = lock,
        };
    }

    pub fn deinit(self: *Node) void {
        self.stopCacheThread();
        self.bootstrap_running.store(false, .release);
        if (self.bootstrap_thread) |t| {
            t.join();
        }
        self.allocator.destroy(self.bootstrap_running);

        // Stop network traffic, then wait for request handlers still running
        // on detached threads. Everything freed below is reachable from them,
        // so nothing is freed before this returns.
        self.connection_manager.stop();
        self.discovery_node.drainHandlers();
        self.connection_manager.relay_dialer = null;
        if (self.keeper) |k| {
            k.stop();
            self.allocator.destroy(k);
        }
        if (self.folder_backup) |b| b.destroy();
        if (self.shares) |index| index.destroy();
        if (self.swarm) |folder| folder.destroy();
        if (self.read_ahead) |ra| ra.destroy();

        self.known_peers.deinit();
        self.allocator.destroy(self.known_peers);
        self.redial.deinit(self.allocator);
        self.membership.close();
        self.allocator.destroy(self.membership);
        self.allocator.free(self.membership_nickname);
        self.policy.destroy();
        self.trust_store.deinit();
        self.allocator.free(self.info_provider.storage_path);
        self.allocator.destroy(self.info_provider);
        self.allocator.destroy(self.trust_store);
        self.device_paths.deinit(self.allocator);

        self.ring.deinit();
        self.allocator.destroy(self.ring);
        self.block_manager.deinit();
        self.discovery_node.deinit();
        self.allocator.destroy(self.discovery_node);
        if (self.store) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.connection_manager.deinit();
        self.allocator.destroy(self.connection_manager);
        // Last: another node may start once everything is saved and closed.
        self.lock.close(std.Io.Threaded.global_single_threaded.io());
    }

    pub const Delivery = struct {
        /// Trust-store label, or a short device ID for unpaired devices.
        name: []u8,
        status: enum { delivered, refused, not_paired, offline, failed },
    };

    /// Hands a new swarm key to every reachable *trusted* device. Peers
    /// whose verified device identity isn't in the trust store are skipped
    /// (they only know the old key); trusted devices that can't be reached
    /// are reported offline. Names are owned by the caller (free each and
    /// the slice).
    pub fn rotateSwarmKey(self: *Node, allocator: std.mem.Allocator, new_key: [32]u8, epoch: u64) ![]Delivery {
        var out: std.ArrayList(Delivery) = .empty;
        errdefer {
            for (out.items) |d| allocator.free(d.name);
            out.deinit(allocator);
        }
        var reached: std.ArrayList(net.id.NodeID) = .empty;
        defer reached.deinit(allocator);

        const peers = try fs.remote.knownPeers(self.block_manager, allocator);
        defer allocator.free(peers);
        for (peers) |peer| {
            const conn = self.block_manager.connectTo(peer) catch continue;
            defer conn.deinit();
            const dev = conn.getRemoteDeviceID() orelse continue;
            const entry = self.trust_store.lookup(dev);
            const trusted = entry != null and self.trust_store.isTrusted(dev);
            if (!trusted) {
                const hex = std.fmt.bytesToHex(dev.bytes[0..4].*, .lower);
                try out.append(allocator, .{ .name = try allocator.dupe(u8, &hex), .status = .not_paired });
                continue;
            }
            try reached.append(allocator, dev);
            const ok = self.discovery_node.sendRotation(conn, new_key, epoch) catch |err| blk: {
                std.debug.print("rotation: sending to {s} failed: {any}\n", .{ entry.?.labelSlice(), err });
                break :blk null;
            };
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, entry.?.labelSlice()),
                .status = if (ok) |accepted| (if (accepted) .delivered else .refused) else .failed,
            });
        }
        // Paired devices that weren't reachable keep the old key.
        const entries = try self.trust_store.copyEntries(allocator);
        defer allocator.free(entries);
        for (entries) |e| {
            const dev = net.id.NodeID.fromPublicKey(e.public_key);
            if (!self.trust_store.isTrusted(dev)) continue;
            const seen = for (reached.items) |r| {
                if (r.eql(dev)) break true;
            } else false;
            if (seen) continue;
            try out.append(allocator, .{ .name = try allocator.dupe(u8, e.labelSlice()), .status = .offline });
        }
        self.discovery_node.setSwarmEpoch(epoch);
        return out.toOwnedSlice(allocator);
    }

    /// Starts the listener, then blocks until `running` is cleared.
    pub fn run(self: *Node, running: *std.atomic.Value(bool), cfg: config.Config) !void {
        try self.listen(running, cfg);
        while (running.load(.acquire)) {
            sync.sleep(100 * std.time.ns_per_ms);
        }
        // Signal bootstrap thread to stop if main loop stops
        self.bootstrap_running.store(false, .release);
    }

    // ---- Reading files ----

    /// A file to read: a swarm folder file (its CID and the device that
    /// wrote that version), or a file a device shares.
    pub const FileSource = union(enum) {
        swarm: struct { cid: [32]u8, author: [32]u8 },
        share: struct { peer: net.id.NodeID, cid: [32]u8 },
    };

    /// Reads up to `dest.len` bytes at `offset`; 0 at the end. Blocks come
    /// from wherever they are held (cluster/fetcher.zig).
    pub fn readFile(self: *Node, allocator: std.mem.Allocator, source: FileSource, offset: u64, dest: []u8) !usize {
        if (self.store == null) return error.StorageDisabled;
        return switch (source) {
            .swarm => |f| (self.swarm orelse return error.StorageDisabled).readAt(allocator, f.cid, f.author, offset, dest),
            .share => |f| fs.remote.readShareAt(allocator, self.block_manager, self.read_ahead, f.peer, f.cid, offset, dest),
        };
    }

    /// Copies a file to `path`, which must not exist (deleted again if the
    /// copy fails). Returns its size.
    pub fn saveFile(self: *Node, allocator: std.mem.Allocator, source: FileSource, path: []const u8) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        defer file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const chunk = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(chunk);
        var offset: u64 = 0;
        // Bounded by the file's size: every round reads more of it, or ends.
        while (true) {
            const n = try self.readFile(allocator, source, offset, chunk);
            if (n == 0) break;
            try file.writePositionalAll(io, chunk[0..n], offset);
            offset += n;
        }
        return offset;
    }

    // ---- Settings applied to the running node (settings.zig saves them) ----

    /// Keep a copy of every swarm folder file here, or not; peers learn it
    /// from the roles in pings.
    pub fn setSwarmBackup(self: *Node, on: bool) !void {
        if (self.swarm) |folder| try folder.setBackup(on);
        self.discovery_node.setRole(net.discovery.rpc.Roles.swarm_backup, on);
    }

    /// Whether this device keeps copies of other devices' swarm files:
    /// signed into the swarm's policy (spread on the next pings) and
    /// announced in the roles.
    pub fn setAcceptCopies(self: *Node, on: bool) !void {
        _ = try self.policy.setAccepts(self.device_identity, self.trust_store, on, nowSeconds());
        self.discovery_node.setRole(net.discovery.rpc.Roles.accepts_copies, on);
        if (self.keeper) |k| k.wake();
    }

    /// The swarm's `copies`, signed by this device; the keeper re-plans.
    pub fn setCopies(self: *Node, n: u8) !void {
        _ = try self.policy.setCopies(self.device_identity, self.trust_store, n, nowSeconds());
        if (self.keeper) |k| k.wake();
    }

    /// Shares a folder (scanned at once), or replaces the folder of a share.
    pub fn addShare(self: *Node, name: []const u8, path: []const u8) !void {
        const index = self.shares orelse return error.StorageDisabled;
        try index.add(name, path);
        try index.start();
    }

    /// Stops sharing a folder; false if it wasn't shared.
    pub fn removeShare(self: *Node, name: []const u8) !bool {
        const index = self.shares orelse return error.StorageDisabled;
        return index.remove(name);
    }

    /// Asks the swarm's backup devices to keep a copy of a share, or stops
    /// asking (copies already made stay on them).
    pub fn setShareBackup(self: *Node, name: []const u8, on: bool) !void {
        const index = self.shares orelse return error.StorageDisabled;
        try index.setBackup(name, on);
    }

    /// Which backup devices hold this device's marked shares (fs/backup.zig).
    /// Allocated in `allocator`: pass an arena.
    pub fn backupCopies(self: *Node, allocator: std.mem.Allocator) ![]fs.backup.ShareCopies {
        const index = self.shares orelse return error.StorageDisabled;
        if (self.store == null) return error.StorageDisabled;
        return fs.backup.copiesOf(allocator, self.block_manager, index, self.trust_store, self.device_identity.deviceId().bytes);
    }

    /// The read cache's size and limit.
    pub fn cacheStats(self: *Node) !storage.engine.StorageEngine.CacheStats {
        const store = self.store orelse return error.StorageDisabled;
        return store.cacheStats();
    }

    /// Empties the read cache; returns the bytes freed. Kept blocks stay.
    pub fn clearCache(self: *Node) !u64 {
        const store = self.store orelse return error.StorageDisabled;
        return store.clearCache();
    }

    /// The read cache's limit in MiB (0: none).
    pub fn setCacheLimit(self: *Node, mb: u64) !void {
        const store = self.store orelse return error.StorageDisabled;
        const bytes = std.math.mul(u64, mb, 1024 * 1024) catch return error.InvalidLimit;
        try store.setCacheLimit(if (mb == 0) null else bytes);
    }

    /// Binds the listener and returns. The accept and
    /// maintenance threads run on their own. `running` must stay alive until
    /// stopListener() returns: the accept loop polls it.
    pub fn listen(self: *Node, running: *std.atomic.Value(bool), cfg: config.Config) !void {
        try self.connection_manager.start();
        try self.connection_manager.listen(cfg, running);
        if (self.folder_backup) |b| b.start() catch |err| std.debug.print("backup: thread not started: {any}\n", .{err});
        if (self.keeper) |k| k.start() catch |err| std.debug.print("keeper: thread not started: {any}\n", .{err});
        if (self.store != null and self.cache_thread == null) {
            self.cache_running.store(true, .release);
            self.cache_thread = std.Thread.spawn(.{}, runCacheSort, .{self}) catch null;
        }
    }

    fn stopCacheThread(self: *Node) void {
        self.cache_running.store(false, .release);
        if (self.cache_thread) |t| t.join();
        self.cache_thread = null;
    }

    /// Marker in the cache directory: the one-time sort is done.
    const cache_sorted_marker = ".sorted-v1";
    /// Longest wait for a share that has no root and isn't being scanned.
    const cache_sort_wait_ns: u64 = 30 * std.time.ns_per_min;

    fn runCacheSort(self: *Node) void {
        const store = self.store orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        if (store.cache_dir.statFile(io, cache_sorted_marker, .{})) |_| return else |_| {}
        var waited: u64 = 0;
        const step = 100 * std.time.ns_per_ms;
        // A share's parent blocks are known once its first scan is done. A
        // scan still running is waited for however long it takes (a media
        // disk hashes for hours): sorting meanwhile would move the blocks it
        // writes. Only a share that never gets a root (its folder is gone) is
        // given up on, after cache_sort_wait_ns.
        while (true) : (waited += step) {
            switch (self.sharesState()) {
                .scanned => break,
                .indexing => {},
                .missing_roots => if (waited >= cache_sort_wait_ns) break,
            }
            if (!self.cache_running.load(.acquire)) return;
            sync.sleep(step);
        }
        if (!self.cache_running.load(.acquire)) return;
        self.sortLegacyCache(store) catch |err| {
            std.debug.print("cache: sorting old blocks failed: {any}\n", .{err});
            return;
        };
        if (store.cache_dir.createFile(io, cache_sorted_marker, .{})) |f| f.close(io) else |_| {}
    }

    fn sharesState(self: *Node) enum { scanned, indexing, missing_roots } {
        const shares = self.shares orelse return .scanned;
        const snap = shares.snapshot(self.allocator) catch return .indexing;
        defer fs.ShareIndex.freeSnapshot(self.allocator, snap);
        var missing = false;
        for (snap) |sh| {
            if (sh.indexing) return .indexing;
            if (sh.root == null) missing = true;
        }
        return if (missing) .missing_roots else .scanned;
    }

    /// Blocks stored before the read cache existed sit with the kept ones.
    /// Keeps what this device is responsible for (its shares' parent and dir
    /// blocks, swarm folder files it wrote or backed up) and moves the rest,
    /// blocks fetched only to be read, into the read cache.
    fn sortLegacyCache(self: *Node, store: *storage.engine.StorageEngine) !void {
        var keep: storage.dag.walk.CidSet = .empty;
        defer keep.deinit(self.allocator);
        if (self.shares) |shares| {
            const snap = try shares.snapshot(self.allocator);
            defer fs.ShareIndex.freeSnapshot(self.allocator, snap);
            for (snap) |sh| if (sh.root) |r| try storage.dag.walk.addStoredReachable(self.allocator, store, &r, &keep);
            // Folder backups kept for other devices.
            const held = try shares.heldSnapshot(self.allocator);
            defer fs.ShareIndex.freeHeldSnapshot(self.allocator, held);
            for (held) |h| try storage.dag.walk.addStoredReachable(self.allocator, store, &h.root, &keep);
        }
        if (self.swarm) |swarm| {
            const roots = try swarm.keptRoots(self.allocator);
            defer self.allocator.free(roots);
            for (roots) |*r| try storage.dag.walk.addStoredReachable(self.allocator, store, r, &keep);
        }
        const moved = try store.demoteExcept(&keep);
        std.debug.print("cache: moved {d} blocks ({d} bytes) read from other devices into the read cache\n", .{ moved.blocks, moved.bytes });
    }

    /// Stops the listener and closes every session, joining the listener's
    /// threads. Request handlers may still be finishing; deinit waits for
    /// them. Stopping is not undone here: a later listen() fails with
    /// ManagerStopping until the connection manager can restart.
    pub fn stopListener(self: *Node) void {
        self.stopCacheThread();
        if (self.keeper) |k| k.stop();
        if (self.folder_backup) |b| b.stop();
        self.bootstrap_running.store(false, .release);
        self.connection_manager.stop();
    }

    pub fn bootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) !void {
        if (self.bootstrap_thread) |t| {
            // Signal stop
            self.bootstrap_running.store(false, .release);
            t.join();
            self.bootstrap_thread = null;
        }
        // Set for the new thread. stopListener() and run() clear it, so this
        // also covers a node that stopped before its first bootstrap.
        self.bootstrap_running.store(true, .release);

        self.bootstrap_thread = try std.Thread.spawn(.{}, runBootstrap, .{ self, peer_urls, swarm_key });
    }

    fn runBootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) void {
        for (peer_urls) |peer_url| {
            if (!self.bootstrap_running.load(.acquire)) return;
            self.connectBootstrapPeer(peer_url, swarm_key);
        }
        self.dialKnownPeers(swarm_key);

        std.debug.print("Bootstrap connections complete. Starting periodic peer discovery and maintenance...\n", .{});
        const discovery_node = self.discovery_node;

        // 1. Initial Self-Lookup (Once)
        if (self.bootstrap_running.load(.acquire)) {
            std.debug.print("Starting initial self-lookup...\n", .{});
            discovery_node.lookup(self.connection_manager.node_id) catch |err| {
                std.debug.print("Error during self-lookup: {any}\n", .{err});
            };
            std.debug.print("Initial self-lookup complete. Routing table dump:\n", .{});
            {
                // Request handlers change the table under this mutex.
                discovery_node.mutex.lock();
                defer discovery_node.mutex.unlock();
                discovery_node.routing_table.dump();
            }
            self.rememberPeers();
        }

        // 2. Keep finding devices. A personal swarm is a handful of devices
        // that come and go (a phone joins after this one started, a laptop
        // wakes up), and the one-time lookup above only saw who was there
        // then: look again every 30 s, which costs a few small requests.
        // Then the standard refresh of buckets nobody touched for an hour.
        var round: u32 = 0;
        while (self.sleepWhileBootstrapping(30 * std.time.ns_per_s)) : (round +%= 1) {
            // What PINGs say about this device: the network may have
            // changed under us (Wi-Fi to mobile data and back).
            discovery_node.setRole(net.discovery.rpc.Roles.metered, !net.local_addrs.onUnmeteredNetwork());
            // Devices the command line added while this node runs (--invite,
            // --trust, --revoke): merged in, and vouched for to the swarm by
            // the membership push like any other member.
            if (self.trust_store.syncFromDisk() catch false) std.debug.print("trust: picked up changes to {s}\n", .{self.trust_store.path});
            // Back in touch with devices we lost (we changed networks, they
            // woke up), then ask around for new ones, then remember them all.
            self.dialKnownPeers(swarm_key);
            discovery_node.lookup(self.connection_manager.node_id) catch |err| {
                std.debug.print("Peer lookup error: {any}\n", .{err});
            };
            self.rememberPeers();
            if (round % 2 != 1) continue;
            discovery_node.refreshBuckets() catch |err| {
                std.debug.print("Bucket refresh error: {any}\n", .{err});
            };
            // Revocation anti-entropy: the push-on-connect path misses peers
            // that never dial us until they do.
            _ = discovery_node.sweepRevocations(4) catch |err| {
                std.debug.print("Revocation sweep error: {any}\n", .{err});
            };
            _ = discovery_node.sweepAdmissions(4) catch |err| {
                std.debug.print("Membership sweep error: {any}\n", .{err});
            };
        }
    }

    const Redial = struct { at_ms: i64, failures: u8 };

    /// Connects to every remembered device (all its addresses, LAN first,
    /// then Tailscale, then public) and pings it, which refreshes both
    /// sides' routing tables and addresses. A connected device costs one
    /// ping; one that doesn't answer is tried again later and later (30 s
    /// up to 5 min).
    fn dialKnownPeers(self: *Node, swarm_key: []const u8) void {
        const now = sync.monotonicMillis();
        const entries = self.allocator.dupe(net.discovery.known_peers.Entry, self.known_peers.entries.items) catch return;
        defer self.allocator.free(entries);
        self.pruneRedial(entries);
        for (entries) |e| {
            if (!self.bootstrap_running.load(.acquire)) return;
            if (e.id.eql(self.connection_manager.node_id)) continue;
            if (self.redial.get(e.id)) |r| if (r.at_ms > now) continue;
            const conn = self.connection_manager.connectToPeerMulti(e.slice(), swarm_key, e.id) catch {
                const failures = if (self.redial.get(e.id)) |r| r.failures +| 1 else 1;
                const wait_ms = @min(@as(i64, 30_000) << @intCast(@min(failures - 1, 4)), 5 * 60_000);
                self.redial.put(self.allocator, e.id, .{ .at_ms = now + wait_ms, .failures = failures }) catch {};
                continue;
            };
            defer conn.deinit();
            _ = self.redial.remove(e.id);
            self.discovery_node.ping(conn) catch {};
        }
    }

    /// Keeps redial state only for devices still in `entries`, so the map
    /// cannot outgrow the list it is keyed from. On allocation failure the
    /// old map stays as it is.
    fn pruneRedial(self: *Node, entries: []const net.discovery.known_peers.Entry) void {
        var kept: std.AutoHashMapUnmanaged(net.id.NodeID, Redial) = .empty;
        for (entries) |e| {
            const r = self.redial.get(e.id) orelse continue;
            kept.put(self.allocator, e.id, r) catch {
                kept.deinit(self.allocator);
                return;
            };
        }
        self.redial.deinit(self.allocator);
        self.redial = kept;
    }

    /// Adds what the routing table knows to the remembered devices.
    fn rememberPeers(self: *Node) void {
        const peers = blk: {
            self.discovery_node.mutex.lock();
            defer self.discovery_node.mutex.unlock();
            break :blk self.discovery_node.routing_table.getAllPeers() catch return;
        };
        defer self.discovery_node.routing_table.allocator.free(peers);
        const changed = self.known_peers.merge(peers) catch return;
        if (changed) self.known_peers.save() catch |err| std.debug.print("Saving known devices failed: {any}\n", .{err});
    }

    /// Sleeps up to `total_ns`, waking early when bootstrapping is cancelled.
    /// Returns whether bootstrapping is still running.
    fn sleepWhileBootstrapping(self: *Node, total_ns: u64) bool {
        const sleep_chunk = 100 * std.time.ns_per_ms;
        var elapsed: u64 = 0;
        while (elapsed < total_ns) : (elapsed += sleep_chunk) {
            if (!self.bootstrap_running.load(.acquire)) return false;
            sync.sleep(sleep_chunk);
        }
        return self.bootstrap_running.load(.acquire);
    }

    fn connectBootstrapPeer(self: *Node, peer_url: []const u8, swarm_key: []const u8) void {
        const address = parseBootstrapUrl(peer_url) orelse return;
        std.debug.print("Bootstrapping: Connecting to {s}...\n", .{peer_url});

        const max_attempts = 5;
        var attempts: usize = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            if (!self.bootstrap_running.load(.acquire)) return;

            const conn = self.connection_manager.connectToPeer(address, swarm_key, null) catch |err| {
                if (attempts == max_attempts - 1) {
                    std.debug.print("Failed to connect to bootstrap peer {s} after {d} attempts: {any}\n", .{ peer_url, max_attempts, err });
                    return;
                }
                std.debug.print("Retry {d}/{d} for {s}: {any}\n", .{ attempts + 1, max_attempts, peer_url, err });
                if (!self.sleepWhileBootstrapping(1 * std.time.ns_per_s)) return;
                continue;
            };
            defer conn.deinit();

            std.debug.print("Successfully connected to bootstrap peer: {s}\n", .{peer_url});
            self.discovery_node.ping(conn) catch {};

            // Request AutoNAT dial-back
            self.discovery_node.checkReachability(conn) catch |err| {
                std.debug.print("AutoNAT request failed: {any}\n", .{err});
            };
            return;
        }
    }

    /// Parses "tcp://host:port" or "host:port"; logs and returns null if invalid.
    fn parseBootstrapUrl(peer_url: []const u8) ?net.compat.Address {
        var addr_part = peer_url;
        if (std.mem.startsWith(u8, addr_part, "tcp://")) {
            addr_part = addr_part[6..];
        }

        const colon_idx = std.mem.lastIndexOfScalar(u8, addr_part, ':') orelse {
            std.debug.print("Invalid bootstrap peer URL: {s}\n", .{peer_url});
            return null;
        };
        const host = addr_part[0..colon_idx];
        const port = std.fmt.parseInt(u16, addr_part[colon_idx + 1 ..], 10) catch {
            std.debug.print("Invalid port in bootstrap peer URL: {s}\n", .{peer_url});
            return null;
        };

        return net.compat.Address.parseIp(host, port) catch {
            std.debug.print("Failed to parse IP for bootstrap peer: {s}\n", .{peer_url});
            return null;
        };
    }
};

/// A device was trusted through membership: the membership push tells the
/// swarm on the next ping (its digest changed); nothing else to do here.
fn membershipTrusted(_: *anyopaque, _: *const device.pairing.Ticket) void {}

/// A device was revoked: its connections close and it stops being a holder
/// of anything, under its device ID and its transport node ID.
fn membershipRevoked(ctx: *anyopaque, device_id: net.id.NodeID, transport_key: ?[32]u8) void {
    const bm: *cluster.BlockManager = @ptrCast(@alignCast(ctx));
    _ = bm.net.closePeer(device_id);
    if (bm.holders) |*h| h.forget(device_id);
    if (transport_key) |tk| {
        const node_id = net.id.NodeID.fromPublicKey(tk);
        _ = bm.net.closePeer(node_id);
        if (bm.holders) |*h| h.forget(node_id);
    }
}

fn wakeKeeper(ctx: *anyopaque) void {
    const k: *cluster.keeper.Keeper = @ptrCast(@alignCast(ctx));
    k.wake();
}

/// What GET_NODE_INFO reports (node_info.zig), gathered on request.
pub const InfoProvider = struct {
    store: ?*storage.engine.StorageEngine,
    storage_path: []const u8,
    shares: ?*fs.ShareIndex,
    swarm: ?*fs.SwarmFolder,
    trust: *device.trust.Store,
    manager: *ConnectionManager,
    block_manager: *cluster.BlockManager,
    started_at: u64,

    pub fn info(self: *InfoProvider, allocator: std.mem.Allocator) !node_info.Info {
        const traffic = self.manager.trafficTotals();
        var out: node_info.Info = .{
            .version = .init(version),
            .platform = .init(node_info.platform()),
            .uptime_s = node_info.nowSeconds() -| self.started_at,
            .connections = std.math.lossyCast(u32, self.manager.getConnectionsCount()),
            .trusted = std.math.lossyCast(u32, self.trust.count()),
            .unmetered = net.local_addrs.onUnmeteredNetwork(),
            .bytes_sent = traffic.sent,
            .bytes_received = traffic.received,
        };
        if (fs.remote.knownPeers(self.block_manager, allocator)) |peers| {
            out.peers = std.math.lossyCast(u32, peers.len);
            allocator.free(peers);
        } else |_| {}
        if (node_info.disk(self.storage_path)) |d| {
            out.disk_total = d.total;
            out.disk_free = d.free;
        }
        if (self.store) |s| {
            if (s.keptUsage()) |k| {
                out.kept_bytes = k.bytes;
                out.kept_blocks = k.blocks;
            } else |_| {}
            const c = s.cacheStats();
            out.cache_bytes = c.bytes;
            out.cache_limit = c.limit orelse 0;
            out.quota = s.quota orelse 0;
        }
        if (self.shares) |index| {
            const snap = try index.snapshot(allocator);
            defer fs.ShareIndex.freeSnapshot(allocator, snap);
            out.shares = std.math.lossyCast(u32, snap.len);
            for (snap) |sh| {
                if (sh.scan_error != null) out.shares_failing += 1;
                if (sh.root == null or sh.indexing) out.shares_indexing += 1;
            }
            const held = try index.heldSnapshot(allocator);
            defer fs.ShareIndex.freeHeldSnapshot(allocator, held);
            out.held_backups = std.math.lossyCast(u32, held.len);
        }
        if (self.swarm) |folder| {
            const st = folder.status();
            out.swarm_files = std.math.lossyCast(u32, st.entries);
            out.swarm_last_sync = st.last_sync;
            const b = folder.backupStatus();
            out.swarm_backup = b.enabled;
            out.swarm_backed_up = std.math.lossyCast(u32, b.backed_up);
            out.swarm_unreachable = std.math.lossyCast(u32, b.unreachable_files);
        }
        return out;
    }

    fn infoErased(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *InfoProvider = @ptrCast(@alignCast(ctx));
        return node_info.encode(allocator, try self.info(allocator));
    }
};

test "Node.pruneRedial keeps state only for remembered devices" {
    const gpa = std.testing.allocator;
    var node: Node = undefined;
    node.allocator = gpa;
    node.redial = .empty;
    defer node.redial.deinit(gpa);

    const kept_id = net.id.NodeID{ .bytes = [_]u8{1} ** 32 };
    const gone_id = net.id.NodeID{ .bytes = [_]u8{2} ** 32 };
    try node.redial.put(gpa, kept_id, .{ .at_ms = 5, .failures = 2 });
    try node.redial.put(gpa, gone_id, .{ .at_ms = 9, .failures = 1 });

    const entries = [_]net.discovery.known_peers.Entry{.{ .id = kept_id, .last_seen = 0 }};
    node.pruneRedial(&entries);

    try std.testing.expectEqual(@as(usize, 1), node.redial.count());
    const r = node.redial.get(kept_id).?;
    try std.testing.expectEqual(@as(i64, 5), r.at_ms);
    try std.testing.expectEqual(@as(u8, 2), r.failures);
}

test "Node.rotateSwarmKey compiles" {
    std.testing.refAllDecls(Node);
    _ = &Node.rotateSwarmKey;
}
