//! Relaying: reaching a device through another one when none of its
//! addresses answers, and piping streams for others (transport/relay.zig
//! does the splicing).

const sync = @import("../../sync.zig");
const std = @import("std");
const id = @import("../id.zig");
const rpc = @import("rpc.zig");
const network = @import("../transport/mod.zig");
const relay = network.relay;
const device_trust = @import("../../device/trust.zig");
const device_rotation = @import("../../device/rotation.zig");
const policy_mod = @import("../../device/policy.zig");
const pruneRecent = @import("recent.zig").pruneRecent;

/// The relaying part of the DHT node `Node` (discovery/node.zig).
// @atlas allow: a type (Node's relaying methods), not one long function
pub fn Relay(comptime Node: type) type {
    return struct {
        const RelayOut = struct { stream: network.Stream, via: network.Connection };

        /// Lets the connection manager reach devices through others when none
        /// of their addresses answers. Call once the node has its final address.
        pub fn enableRelay(self: *Node) void {
            self.manager.relay_dialer = .{ .ctx = self, .dialFn = dialThroughRelayErased };
        }

        pub fn dialThroughRelayErased(ctx: *anyopaque, target: id.NodeID) anyerror!network.Connection {
            const self: *Node = @ptrCast(@alignCast(ctx));
            return dialThroughRelay(self, target);
        }

        /// Asks each device this one is connected to to pipe a stream to
        /// `target`, and runs the connection over the first that does.
        /// Returns a reference the caller must deinit().
        pub fn dialThroughRelay(self: *Node, target: id.NodeID) !network.Connection {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                pruneRecent(&self.relay_misses, sync.monotonicMillis());
                if (self.relay_misses.get(target)) |until| {
                    if (sync.monotonicMillis() < until) return error.NoRelay;
                }
            }
            const conn = dialThroughRelayOnce(self, target) catch |err| {
                self.mutex.lock();
                defer self.mutex.unlock();
                const now = sync.monotonicMillis();
                pruneRecent(&self.relay_misses, now);
                if (self.relay_misses.count() < Node.max_recent_peers) {
                    self.relay_misses.put(self.allocator, target, now + Node.relay_retry_ms) catch {};
                }
                return err;
            };
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.relay_misses.remove(target);
            return conn;
        }

        pub fn dialThroughRelayOnce(self: *Node, target: id.NodeID) !network.Connection {
            const conns = try self.manager.liveConnections(self.allocator);
            defer {
                for (conns) |c| c.deinit();
                self.allocator.free(conns);
            }
            for (conns) |via| {
                if (via.getRemoteNodeID().eql(target)) continue;
                if (via.getPeerAddress().isUnspecified()) continue; // relays don't chain
                const stream = via.openStream() catch continue;
                if (!requestRelay(self, stream, target)) {
                    stream.close();
                    continue;
                }
                via.retain();
                const conn = relay.establish(self.allocator, stream, via, self.swarm_key, self.manager.identity_key, true, self.manager.handshake_timeout_ms, self.manager.deviceAuthPtr()) catch |err| {
                    std.debug.print("relay: handshake with {x} through {x} failed: {any}\n", .{ target.bytes[0..4], via.getRemoteNodeID().bytes[0..4], err });
                    continue;
                };
                if (!conn.getRemoteNodeID().eql(target)) {
                    conn.deinit();
                    continue;
                }
                std.debug.print("relay: reached {x} through {x}\n", .{ target.bytes[0..4], via.getRemoteNodeID().bytes[0..4] });
                // One reference for the manager, one for the caller.
                conn.retain();
                self.manager.addConnection(conn) catch conn.deinit();
                return conn;
            }
            return error.NoRelay;
        }

        /// RELAY_CONNECT on `stream`; true when the relay answered ok.
        pub fn requestRelay(self: *Node, stream: network.Stream, target: id.NodeID) bool {
            stream.setTimeout(Node.relay_setup_timeout_ms);
            const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_CONNECT = .{ .target = target } } };
            msg.send(self.allocator, stream) catch return false;
            // Older nodes don't know RELAY_CONNECT: they close the stream.
            const reply = rpc.Message.deserialize(self.allocator, stream.reader()) catch return false;
            defer reply.deinit(self.allocator);
            return reply.payload == .RELAY_ACK and reply.payload.RELAY_ACK.ok;
        }

        pub fn sendRelayAck(self: *Node, stream: network.Stream, ok: bool) !void {
            const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_ACK = .{ .ok = ok } } };
            try msg.send(self.allocator, stream);
        }

        /// RELAY_CONNECT from `conn`'s device: pipes `stream` to `target` until
        /// either end closes. Takes ownership of `stream`. Only devices of the
        /// swarm can ask (the connection is authenticated), and the target is
        /// reached directly, never through another relay.
        pub fn handleRelayConnect(self: *Node, stream: network.Stream, conn: network.Connection, target: id.NodeID) void {
            const from = conn.getRemoteNodeID();
            const out = openRelayStream(self, from, target) orelse {
                sendRelayAck(self, stream, false) catch {};
                stream.close();
                return;
            };
            defer _ = self.active_relays.fetchSub(1, .acq_rel);
            defer out.via.deinit();
            sendRelayAck(self, stream, true) catch {
                stream.close();
                out.stream.close();
                return;
            };
            std.debug.print("relay: piping {x} to {x}\n", .{ from.bytes[0..4], target.bytes[0..4] });
            relay.splice(stream, out.stream);
            std.debug.print("relay: {x} to {x} closed\n", .{ from.bytes[0..4], target.bytes[0..4] });
        }

        /// A stream to `target` that it accepted for `from` (RELAY_INCOMING),
        /// counted in active_relays; null if it can't be had.
        pub fn openRelayStream(self: *Node, from: id.NodeID, target: id.NodeID) ?RelayOut {
            if (target.eql(self.manager.node_id) or target.eql(from)) return null;
            if (self.active_relays.fetchAdd(1, .acq_rel) >= Node.max_relays) {
                _ = self.active_relays.fetchSub(1, .acq_rel);
                return null;
            }
            var counted = true;
            defer if (counted) {
                _ = self.active_relays.fetchSub(1, .acq_rel);
            };

            const via = self.manager.existingConnection(target) orelse blk: {
                const peer = peer: {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    break :peer self.routing_table.getPeer(target);
                } orelse return null;
                break :blk self.manager.connectDirect(peer.addresses[0..peer.addrs_count], self.swarm_key, target) catch return null;
            };
            if (via.getPeerAddress().isUnspecified()) {
                via.deinit(); // relayed itself: relays don't chain
                return null;
            }
            const stream = via.openStream() catch {
                via.deinit();
                return null;
            };
            stream.setTimeout(Node.relay_setup_timeout_ms);
            const ok = blk: {
                const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_INCOMING = .{ .from = from } } };
                msg.send(self.allocator, stream) catch break :blk false;
                const reply = rpc.Message.deserialize(self.allocator, stream.reader()) catch break :blk false;
                defer reply.deinit(self.allocator);
                break :blk reply.payload == .RELAY_ACK and reply.payload.RELAY_ACK.ok;
            };
            if (!ok) {
                stream.close();
                via.deinit();
                return null;
            }
            counted = false;
            return .{ .stream = stream, .via = via };
        }

        /// RELAY_INCOMING: `from` connects to this node through `conn`'s
        /// device over `stream`. Returns whether the stream was taken.
        pub fn handleRelayIncoming(self: *Node, stream: network.Stream, conn: network.Connection, from: id.NodeID) bool {
            sendRelayAck(self, stream, true) catch return false;
            conn.retain();
            const relayed = relay.establish(self.allocator, stream, conn, self.swarm_key, self.manager.identity_key, false, self.manager.handshake_timeout_ms, self.manager.deviceAuthPtr()) catch |err| {
                std.debug.print("relay: handshake with {x} failed: {any}\n", .{ from.bytes[0..4], err });
                return true;
            };
            if (!relayed.getRemoteNodeID().eql(from)) {
                relayed.deinit();
                return true;
            }
            std.debug.print("relay: {x} connected through {x}\n", .{ from.bytes[0..4], conn.getRemoteNodeID().bytes[0..4] });
            self.manager.addConnection(relayed) catch relayed.deinit();
            return true;
        }
    };
}
