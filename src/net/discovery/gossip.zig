//! Membership news between devices, over the DHT's connections:
//! revocations and admissions (device/trust.zig decides), swarm key
//! rotations (device/rotation.zig) and the swarm policy
//! (device/policy.zig). The transport only carries them.

const sync = @import("../../sync.zig");
const std = @import("std");
const id = @import("../id.zig");
const rpc = @import("rpc.zig");
const network = @import("../transport/mod.zig");
const relay = network.relay;
const device_trust = @import("../../device/trust.zig");
const device_rotation = @import("../../device/rotation.zig");
const policy_mod = @import("../../device/policy.zig");

/// The membership-news part of the DHT node `Node` (discovery/node.zig).
// @atlas allow: a type (Node's membership methods), not one long function
pub fn Gossip(comptime Node: type) type {
    return struct {
        /// Hands `new_key` (epoch) to `conn`'s peer, signed with this device's
        /// identity. Returns whether the peer adopted it. Only call this for a
        /// connection whose device is trusted: the key travels to whoever it is.
        pub fn sendRotation(self: *Node, conn: network.Connection, new_key: [32]u8, epoch: u64) !bool {
            const identity = self.device_identity orelse return error.NoDeviceIdentity;
            const signature = try identity.sign(&device_rotation.message(epoch, new_key));
            const stream = try conn.openStream();
            defer stream.close();
            stream.setTimeout(self.rpc_timeout_ms);
            const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .ROTATE_KEY = .{
                .epoch = epoch,
                .new_key = new_key,
                .signer_key = identity.publicKey(),
                .signature = signature,
            } } };
            try msg.send(self.allocator, stream);
            const response = try rpc.Message.deserialize(self.allocator, stream.reader());
            defer response.deinit(self.allocator);
            return switch (response.payload) {
                .STORE_ACK => |ack| ack.stored,
                else => error.InvalidResponse,
            };
        }

        /// Signs and pushes `device`'s revocation to `conn`'s peer. Fails when
        /// this node has no device identity to sign with.
        pub fn sendRevoke(self: *Node, conn: network.Connection, device_id: id.NodeID) !bool {
            if (self.trust_store) |trust| {
                const tombstones = try trust.copyRevocations(self.allocator);
                defer self.allocator.free(tombstones);
                for (tombstones) |r| {
                    if (r.device_id.eql(device_id)) return sendRevokeAt(self, conn, device_id, r.at);
                }
            }
            const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
            return sendRevokeAt(self, conn, device_id, now);
        }

        pub fn sendRevokeAt(self: *Node, conn: network.Connection, device_id: id.NodeID, at: u64) !bool {
            const identity = self.device_identity orelse return error.NoDeviceIdentity;
            const signed = device_trust.revocationMessage(device_id, identity.deviceId(), at);
            const stream = try conn.openStream();
            defer stream.close();
            stream.setTimeout(self.rpc_timeout_ms);

            const signature = try identity.sign(&signed);

            const msg = rpc.Message{
                .sender_id = self.manager.node_id,
                .payload = .{ .REVOKE = .{ .device_id = device_id, .signer_key = identity.publicKey(), .at = at, .signature = signature } },
            };
            try msg.send(self.allocator, stream);

            const response = try rpc.Message.deserialize(self.allocator, stream.reader());
            defer response.deinit(self.allocator);
            switch (response.payload) {
                .STORE_ACK => |ack| return ack.stored,
                else => return error.InvalidResponse,
            }
        }

        /// Sends every tombstone this node holds to `conn`'s peer, so a newly
        /// connected peer learns which devices were removed elsewhere. Returns
        /// how many peers honored them. No-op without tombstones or an identity.
        pub fn pushRevocations(self: *Node, conn: network.Connection) !usize {
            const trust = self.trust_store orelse return 0;
            if (self.device_identity == null) return 0;
            const tombstones = try trust.copyRevocations(self.allocator);
            defer self.allocator.free(tombstones);

            var honored: usize = 0;
            for (tombstones) |r| {
                const ok = sendRevokeAt(self, conn, r.device_id, r.at) catch |err| {
                    std.debug.print("Failed to push revocation of {x}: {any}\n", .{ r.device_id.bytes[0..4], err });
                    continue;
                };
                if (ok) honored += 1;
            }
            return honored;
        }

        /// Sends every policy record to `conn`'s peer, unless it acknowledged
        /// this exact set before: a change costs one message per record per
        /// peer, an unchanged policy nothing. Returns how many it took.
        pub fn pushPolicy(self: *Node, conn: network.Connection) !usize {
            const policy = self.policy orelse return 0;
            const peer = conn.getRemoteDeviceID() orelse return 0;
            const digest = policy.digest();
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.policy_sent.get(peer)) |d| if (d == digest) return 0;
            }
            const records = try policy.records(self.allocator);
            defer self.allocator.free(records);
            if (records.len == 0) return 0;
            var taken: usize = 0;
            for (records) |r| {
                const stream = conn.openStream() catch break;
                defer stream.close();
                stream.setTimeout(self.rpc_timeout_ms);
                const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .POLICY = .{ .record = r.encode() } } };
                msg.send(self.allocator, stream) catch break;
                const response = rpc.Message.deserialize(self.allocator, stream.reader()) catch break;
                defer response.deinit(self.allocator);
                switch (response.payload) {
                    .STORE_ACK => |ack| if (ack.stored) {
                        taken += 1;
                    },
                    else => break,
                }
            }
            // Remembered only when every record was acknowledged.
            if (taken == records.len) {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.policy_sent.count() >= 256) self.policy_sent.clearRetainingCapacity();
                self.policy_sent.put(self.allocator, peer, digest) catch {};
            }
            return taken;
        }

        /// POLICY: a signed swarm setting; applied when newer, acknowledged
        /// when not older-and-invalid (device/policy.zig).
        pub fn handlePolicy(self: *Node, stream: network.Stream, bytes: [policy_mod.Record.encoded_len]u8) !void {
            var stored = false;
            if (self.policy) |policy| if (self.trust_store) |trust| if (self.device_identity) |identity| {
                if (policy_mod.Record.decode(&bytes)) |r| {
                    const now = std.math.cast(u64, sync.timestamp()) orelse 0;
                    const outcome = policy.apply(r, trust, identity.deviceId(), now) catch .rejected;
                    stored = outcome != .rejected;
                    if (outcome == .applied) {
                        policy.save() catch |err| std.debug.print("policy: not saved: {any}\n", .{err});
                        if (self.on_policy_change) |cb| cb.func(cb.ctx);
                    }
                } else |_| {}
            };
            const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = stored } } };
            try response.send(self.allocator, stream);
        }

        /// Signs and sends this node's vouch for `entry` (ADMIT): `entry` is a
        /// member here, admitted at `entry.added_at`.
        pub fn sendAdmit(self: *Node, conn: network.Connection, entry: device_trust.Entry) !bool {
            const identity = self.device_identity orelse return error.NoDeviceIdentity;
            const label = entry.labelSlice();
            const signed = device_trust.admissionMessage(entry.public_key, entry.transport_key, label, entry.added_at, identity.deviceId());
            var admit: rpc.Admit = .{
                .public_key = entry.public_key,
                .transport_key = entry.transport_key,
                .at = entry.added_at,
                .signer_key = identity.publicKey(),
                .signature = try identity.sign(&signed),
            };
            @memcpy(admit.label[0..label.len], label);
            admit.label_len = @intCast(label.len);

            const stream = try conn.openStream();
            defer stream.close();
            stream.setTimeout(self.rpc_timeout_ms);
            const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .ADMIT = admit } };
            try msg.send(self.allocator, stream);
            const response = try rpc.Message.deserialize(self.allocator, stream.reader());
            defer response.deinit(self.allocator);
            switch (response.payload) {
                .STORE_ACK => |ack| return ack.stored,
                else => return error.InvalidResponse,
            }
        }

        /// Vouches for every member this node trusts to `conn`'s peer. A peer
        /// that trusts this node adds the ones it doesn't know. Returns how many
        /// it took. Entries without a pinned transport key are not sent.
        pub fn pushAdmissions(self: *Node, conn: network.Connection) !usize {
            const trust = self.trust_store orelse return 0;
            if (self.device_identity == null) return 0;
            const entries = try trust.copyEntries(self.allocator);
            defer self.allocator.free(entries);
            const peer = conn.getRemoteDeviceID();
            var hasher = std.hash.Wyhash.init(0);
            for (entries) |e| {
                hasher.update(&e.device_id.bytes);
                hasher.update(std.mem.asBytes(&e.added_at));
            }
            const digest = hasher.final();
            const now = sync.timestamp();
            if (peer) |p| {
                self.mutex.lock();
                const fresh = if (self.admit_sent.get(p)) |last| last.digest == digest and now -| last.at < last.retryAfter() else false;
                self.mutex.unlock();
                if (fresh) return 0;
            }

            var taken: usize = 0;
            var sent: usize = 0;
            for (entries) |e| {
                if (std.mem.eql(u8, &e.transport_key, &device_trust.no_transport_key)) continue;
                // The peer itself needs no vouch for itself.
                if (peer) |p| if (p.eql(e.device_id)) continue;
                sent += 1;
                const ok = sendAdmit(self, conn, e) catch |err| {
                    std.debug.print("Failed to vouch for {x}: {any}\n", .{ e.device_id.bytes[0..4], err });
                    continue;
                };
                if (ok) taken += 1;
            }
            // Remembered either way: a peer that refused some vouches (it
            // doesn't trust this node yet, or its store is full) hears the list
            // again after a while, not on every ping.
            if (peer) |p| {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.admit_sent.count() >= 256) self.admit_sent.clearRetainingCapacity();
                self.admit_sent.put(self.allocator, p, .{ .digest = digest, .at = now, .complete = taken == sent }) catch {};
            }
            return taken;
        }

        /// Up to `sample` known peers, the closest to this node first (the
        /// sweeps' targets). Caller frees.
        fn samplePeers(self: *Node, sample: usize) ![]@import("kbucket.zig").PeerInfo {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.routing_table.getClosestPeers(self.manager.node_id, sample);
        }

        /// Anti-entropy for membership: vouches for every member to a sample of
        /// known peers, so a device that joined through another member learns
        /// the rest of the swarm even when nobody dials it.
        pub fn sweepAdmissions(self: *Node, sample: usize) !usize {
            const trust = self.trust_store orelse return 0;
            if (trust.count() == 0 or self.device_identity == null) return 0;
            const peers = try samplePeers(self, sample);
            defer self.allocator.free(peers);
            var reached: usize = 0;
            for (peers) |peer| {
                const conn = self.manager.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.swarm_key, peer.id) catch continue;
                defer conn.deinit();
                if ((pushAdmissions(self, conn) catch 0) > 0) reached += 1;
                _ = pushPolicy(self, conn) catch {};
            }
            return reached;
        }

        /// Anti-entropy for revocations: connects to a sample of known peers
        /// and replays every tombstone we hold, so peers that never dialed us
        /// still learn which devices were removed. Returns how many peers
        /// accepted at least one revocation.
        pub fn sweepRevocations(self: *Node, sample: usize) !usize {
            const trust = self.trust_store orelse return 0;
            const tombstones = try trust.copyRevocations(self.allocator);
            defer self.allocator.free(tombstones);
            if (tombstones.len == 0 or self.device_identity == null) return 0;

            const peers = try samplePeers(self, sample);
            defer self.allocator.free(peers);

            var accepted: usize = 0;
            for (peers) |peer| {
                const conn = self.manager.connectToPeerMulti(
                    peer.addresses[0..peer.addrs_count],
                    self.swarm_key,
                    peer.id,
                ) catch |err| {
                    std.debug.print("Revocation sweep: {x} unreachable: {any}\n", .{ peer.id.bytes[0..4], err });
                    continue;
                };
                defer conn.deinit();

                var any_honored = false;
                for (tombstones) |r| {
                    const ok = sendRevokeAt(self, conn, r.device_id, r.at) catch |err| {
                        std.debug.print("Revocation sweep: push to {x} failed: {any}\n", .{ peer.id.bytes[0..4], err });
                        continue;
                    };
                    if (ok) any_honored = true;
                }
                if (any_honored) accepted += 1;
            }
            return accepted;
        }

        pub fn setSwarmEpoch(self: *Node, epoch: u64) void {
            self.rotation_mutex.lock();
            defer self.rotation_mutex.unlock();
            self.swarm_epoch = epoch;
        }

        pub fn handleRotateKey(self: *Node, stream: network.Stream, conn: network.Connection, epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8) !void {
            const accepted = applyRotation(self, conn.getRemoteDeviceID(), epoch, new_key, signer_key, signature);
            const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = accepted } } };
            try response.send(self.allocator, stream);
        }

        pub fn applyRotation(self: *Node, peer_device: ?id.NodeID, epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8) bool {
            self.rotation_mutex.lock();
            defer self.rotation_mutex.unlock();
            if (epoch == std.math.maxInt(u64)) return false;
            const trust = self.trust_store orelse return false;
            const sink = self.rotation_sink orelse return false;
            device_rotation.verify(trust, peer_device, signer_key, signature, epoch, new_key, self.swarm_epoch) catch |err| {
                std.debug.print("Refused a swarm key rotation: {any}\n", .{err});
                return false;
            };
            self.swarm_epoch = epoch;
            sink.applyFn(sink.ctx, new_key, epoch);
            return true;
        }

        /// REVOKE: only honored when the signature verifies, the signer is not
        /// the revoked device, and the signer's Ed25519 identity is in this
        /// node's own trust store. Everything else is refused, never applied.
        pub fn handleRevoke(
            self: *Node,
            stream: network.Stream,
            device_id: id.NodeID,
            signer_key: [32]u8,
            at: u64,
            signature: [64]u8,
        ) !void {
            var honored = false;
            if (self.trust_store) |trust| {
                const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
                // The entry goes with the revocation: read its transport key first.
                const transport_key: ?[32]u8 = if (trust.lookup(device_id)) |e| e.transport_key else null;
                const outcome = device_trust.applyRevocation(trust, device_id, signer_key, at, signature, now) catch .rejected;
                honored = outcome != .rejected;
                if (outcome == .applied) {
                    _ = self.manager.closePeer(device_id);
                    // It stops being a holder too (cluster/holders.zig).
                    if (self.revocation_sink) |sink| sink.revokedFn(sink.ctx, device_id, transport_key);
                }
                // Accepted tombstones must survive a restart, or every re-dial
                // replays the whole revocation.
                if (outcome == .applied) trust.save() catch |err| {
                    std.debug.print("Failed to persist accepted revocation: {any}\n", .{err});
                };
            }
            const response = rpc.Message{
                .sender_id = self.manager.node_id,
                .payload = .{ .STORE_ACK = .{ .stored = honored } },
            };
            try response.send(self.allocator, stream);
        }

        /// ADMIT: a member vouches for a device. Added when this node trusts
        /// the signer and doesn't know the device (device_trust.applyAdmission).
        pub fn handleAdmit(self: *Node, stream: network.Stream, admit: rpc.Admit) !void {
            var taken = false;
            if (self.trust_store) |trust| {
                const self_id = if (self.device_identity) |identity| identity.deviceId() else id.NodeID{ .bytes = [_]u8{0} ** 32 };
                const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
                const outcome = device_trust.applyAdmission(trust, admit.public_key, admit.transport_key, admit.labelSlice(), admit.at, admit.signer_key, admit.signature, self_id, now) catch .rejected;
                taken = outcome != .rejected;
                if (outcome == .applied) trust.save() catch |err| {
                    std.debug.print("Failed to persist a new swarm member: {any}\n", .{err});
                };
            }
            const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = taken } } };
            try response.send(self.allocator, stream);
        }
    };
}
