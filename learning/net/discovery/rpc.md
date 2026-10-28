# Chapter 2.4: DHT RPC and Serialization

Every request one NomadFS device makes of another is a message defined in
`src/net/discovery/rpc.zig`, served by `discovery.Node` in
`src/net/discovery/node.zig`. Despite the name, these messages carry far more
than Kademlia: blocks, share listings, the swarm folder manifest,
revocations and key rotation all use them.

## 1. One RPC per Yamux Stream

```
caller                                   callee (Node.serve)
conn.openStream()           ──SYN──▶     acceptStream(), spawn handler thread
stream.setTimeout(10 s)                  stream.setTimeout(10 s)
Message.serialize(request)  ──────▶      Message.deserialize → handleRequest
Message.deserialize(reply)  ◀──────      Message.serialize(reply)
stream.close()              ──FIN──▶     stream.close()
```

*   One request and at most one reply per [Yamux stream](../transport/yamux.md),
    each bounded by `rpc_timeout_ms = 10_000`. `DIAL_BACK` has no reply.
*   `Node.serve(conn)` is the connection handler set in `src/root.zig`. It
    loops on `acceptStream()` and runs each request on its own thread, which
    holds its own reference to the connection.
*   The sender is the connection's authenticated node ID. Handlers that care
    (`PING`, `ADD_PROVIDER`, `DIAL_BACK`, `ROTATE_KEY`) use
    `conn.getRemoteNodeID()` / `getRemoteDeviceID()`, not the `sender_id`
    field.

## 2. The Message Format

```zig
pub const Message = struct {
    sender_id: id.NodeID,
    payload: MessagePayload, // tagged union over MessageType
};
```

On the wire, all integers big-endian:

```
[type: u8][sender_id: 32 bytes][payload ...]
```

## 3. The 21 Message Types

| # | Type | Payload | Reply |
| --: | :--- | :--- | :--- |
| 0 | `PING` | `port: u16` (sender's listening port) | `PONG` |
| 1 | `PONG` | empty | |
| 2 | `FIND_NODE` | `target: 32 B` | `FIND_NODE_RESPONSE` |
| 3 | `FIND_NODE_RESPONSE` | peer list (section 4) | |
| 4 | `FIND_VALUE` | `key: 32 B` | `FIND_VALUE_RESPONSE` |
| 5 | `FIND_VALUE_RESPONSE` | `1` + value, or `0` + peer list | |
| 6 | `STORE` | `key: 32 B`, value | `STORE_ACK` |
| 7 | `DIAL_BACK` | `port: u16` | none; the callee dials back ([Chapter 1.6](../transport/nat.md)) |
| 8 | `STORE_ACK` | `stored: u8` (0 or 1) | |
| 9 | `GET_BLOCK` | `cid: 32 B` | `BLOCK` |
| 10 | `BLOCK` | `1` + data, or `0` if the block isn't held | |
| 11 | `ADD_PROVIDER` | `key: 32 B` (the provider is the authenticated sender) | `STORE_ACK` |
| 12 | `GET_PROVIDERS` | `key: 32 B` | `PROVIDERS` |
| 13 | `PROVIDERS` | `count: u8` (≤ 20), then `count` × 32-byte node IDs | |
| 14 | `PUT_BLOCK` | `cid: 32 B`, data | `STORE_ACK` (stored only if the bytes hash to `cid`) |
| 15 | `REVOKE` | `device_id: 32 B`, `signer_key: 32 B`, `at: u64`, `signature: 64 B` | `STORE_ACK` |
| 16 | `GET_SHARES` | empty | `SHARES` |
| 17 | `SHARES` | `nick_len: u8`, nickname (≤ 64 B), listing (a dir block) | |
| 18 | `GET_SWARM` | empty | `SWARM` |
| 19 | `SWARM` | the swarm folder manifest (JSON) | |
| 20 | `ROTATE_KEY` | `epoch: u64`, `new_key: 32 B`, `signer_key: 32 B`, `signature: 64 B` | `STORE_ACK` (accepted or not) |

A "value", "data", "listing" or "manifest" is `[len: u32][bytes]`, and
`readValue` refuses lengths above `max_value_len` (10 MiB). An unknown type
byte fails with `error.InvalidMessageType`.

What each handler does:

*   **`GET_BLOCK`** reads the local block store, which also serves shared
    files' chunks from the original files (see
    [Shared folders](../../fs/shares.md)). The caller verifies the bytes
    against the CID ([Blocks](../../storage/block.md)).
*   **`GET_SHARES`** returns the node's nickname and a dir block whose entries
    are its shares (an empty dir block, `{2, 0, 0}`, if it shares nothing).
    **`GET_SWARM`** returns the encoded manifest, or `[]`
    ([Swarm folder](../../fs/swarm.md)).
*   **`REVOKE`** is honored only if the signer is trusted locally
    (`device_trust.applyRevocation`). **`ROTATE_KEY`** is honored only if the
    signer is trusted, *is* the device on this connection, and the epoch is
    newer (`device/rotation.zig`). See
    [Device Identity & Pairing](../../security/pairing.md).
*   **`STORE`** values are bounded per node by `store_limits`: 64 KiB per
    value, 64 MiB in total, 100,000 keys.
*   **`PING`** from the network adds the sender to the routing table under the
    socket's IP and the port in the payload. After a `PONG`, the pinging
    side pushes its revocations to the peer (`pushRevocations`) if it has
    any.

## 4. Peer Records and Addresses

`FIND_NODE_RESPONSE` and the closer-peers form of `FIND_VALUE_RESPONSE`
carry a peer list:

```
[count: u8]                     // ≤ K = 20 on read (error.TooManyPeers)
count × {
    [node_id: 32 B]
    [addr_count: u8]            // ≤ 8 on read (error.TooManyAddresses)
    addr_count × address
}

address = [4][ipv4: 4 B][port: u16 BE]
        | [6][ipv6: 16 B][port: u16 BE]
```

```zig
fn writePeers(peers: []const kbucket.PeerInfo, writer: anytype) !void {
    if (peers.len > 255) return error.TooManyPeers;
    try writer.writeByte(@intCast(peers.len));
    for (peers) |peer| {
        try writer.writeAll(&peer.id.bytes);
        try writer.writeByte(peer.addrs_count);
        for (0..peer.addrs_count) |i| try serializeAddress(peer.addresses[i], writer);
    }
}
```

## 5. Serialization Code

`Message.serialize(writer)` writes the type byte, the sender ID, then switches
on the payload. `Message.deserialize(allocator, reader)` does the reverse.
Variable-length parts (peer lists, values, nicknames, provider lists) are
allocated, and `Message.deinit(allocator)` frees them.

```zig
pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Message {
    const type_byte = try reader.readByte();
    const msg_type = std.enums.fromInt(MessageType, type_byte) orelse return error.InvalidMessageType;
    var sender_id: id.NodeID = undefined;
    try reader.readNoEof(&sender_id.bytes);
    const payload = switch (msg_type) { ... };
    return .{ .sender_id = sender_id, .payload = payload };
}
```

## 6. Safety and Validation

*   **Counts are bounded before allocating**: peers ≤ 20, addresses ≤ 8,
    providers ≤ 20, values ≤ 10 MiB, nicknames ≤ 255 on the wire (cut to 64
    when sending).
*   **Booleans are strict**: `readBool` accepts only 0 or 1
    (`error.InvalidMessage`).
*   **Identity comes from the handshake**: a `PING` whose `sender_id` differs
    from the connection's node ID is refused (`error.PeerIdMismatch`), and the
    caller of `ping()` checks the `PONG` the same way.
*   **Content is checked against its name**: `PUT_BLOCK` goes through
    `StorageEngine.put`, which rejects bytes that don't hash to the CID.

---

**Next Chapters:**
*   [Chapter 3: The Storage Layer](../../storage/overview.md)
