# Chapter 2.4: DHT RPC and Serialization

To communicate between nodes, we need a compact and efficient way to serialize our DHT messages (PING, FIND_NODE, etc.) into raw bytes.

## 1. The Message Protocol

NomadFS uses a simple binary protocol for DHT messages to minimize overhead and avoid the complexity of heavy formats like JSON or XML.

### Message Structure
Every message consists of:
1.  **Type (1 byte)**: The `MessageType` enum.
2.  **Sender ID (32 bytes)**: The `NodeID` of the sender.
3.  **Payload**: Variable length depending on the message type.

## 2. Payload Formats

### PING (0)
*   **Payload**: 
    *   **Port (2 bytes)**: Big-endian. The listening port of the sender (to allow callbacks through NAT/Firewalls).

### PONG (1)
*   **Payload**: Empty (0 bytes).

### FIND_NODE (2)
*   **Payload**: Target `NodeID` (32 bytes).

### FIND_NODE_RESPONSE (3)
*   **Payload**: 
    *   **Count (1 byte)**: Number of peers being returned (max $K=20$).
    *   **Peers**: Array of Peer records.
        *   **ID (32 bytes)**.
        *   **Address Type (1 byte)**: 4 for IPv4, 6 for IPv6.
        *   **IP Address (4 or 16 bytes)**.
        *   **Port (2 bytes)**: Big-endian.

### FIND_VALUE (4)
*   **Payload**: Key `NodeID` (32 bytes).

### FIND_VALUE_RESPONSE (5)
*   **Payload**:
    *   **Found (1 byte)**: 1 if value is found, 0 if returning closer peers.
    *   **If Found**:
        *   **Length (4 bytes)**: Big-endian length of the value.
        *   **Value**: The raw bytes of the value.
    *   **If Not Found** (Closer Peers):
        *   **Count (1 byte)**: Number of peers.
        *   **Peers**: Array of Peer records (same format as `FIND_NODE_RESPONSE`).

### STORE (6)
*   **Payload**:
    *   **Key**: `NodeID` (32 bytes).
    *   **Length (4 bytes)**: Big-endian length of the value.
    *   **Value**: The raw bytes to store.

## 3. Implementation in Zig

The implementation in `src/dht/rpc.zig` uses a `Message` struct with `serialize` and `deserialize` methods.

### Serialization
We use the `std.io.Writer` interface to write bytes directly to the stream.

```zig
pub fn serialize(self: Message, writer: anytype) !void {
    // 1. Write Message Type
    try writer.writeByte(@intFromEnum(self.payload));

    // 2. Write Sender ID
    try writer.writeAll(&self.sender_id.bytes);

    // 3. Write Payload
    switch (self.payload) {
        .PING, .PONG => {},
        .FIND_NODE => |p| {
            try writer.writeAll(&p.target.bytes);
        },
        .FIND_NODE_RESPONSE => |p| {
            try writer.writeByte(@intCast(p.closer_peers.len));
            for (p.closer_peers) |peer| {
                try writer.writeAll(&peer.id.bytes);
                try serializeAddress(peer.address, writer);
            }
        },
        .FIND_VALUE => |p| {
            try writer.writeAll(&p.key.bytes);
        },
        .FIND_VALUE_RESPONSE => |p| {
            switch (p) {
                .value => |val| {
                    try writer.writeByte(1); // Found
                    try writer.writeInt(u32, @intCast(val.len), .big);
                    try writer.writeAll(val);
                },
                .closer_peers => |peers| {
                    try writer.writeByte(0); // Not Found, here are peers
                    try writer.writeByte(@intCast(peers.len));
                    for (peers) |peer| {
                        try writer.writeAll(&peer.id.bytes);
                        try serializeAddress(peer.address, writer);
                    }
                },
            }
        },
        .STORE => |p| {
            try writer.writeAll(&p.key.bytes);
            try writer.writeInt(u32, @intCast(p.value.len), .big);
            try writer.writeAll(p.value);
        },
    }
}
```

### Deserialization
Deserialization requires an `Allocator` because `FIND_NODE_RESPONSE` contains a slice of peers that must be allocated.

```zig
pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Message {
    const type_byte = try reader.readByte();
    const msg_type = std.meta.intToEnum(MessageType, type_byte) catch return error.InvalidMessageType;

    var sender_id: id.NodeID = undefined;
    try reader.readNoEof(&sender_id.bytes);
    
    // ... switch on msg_type and read payload ...
}
```

## 4. Address Handling

Addresses are handled specifically to ensure cross-platform compatibility. IPv4 and IPv6 addresses are serialized with a leading type byte followed by the raw IP bytes and a 2-byte big-endian port.

```zig
fn serializeAddress(addr: std.net.Address, writer: anytype) !void {
    switch (addr.any.family) {
        std.posix.AF.INET => {
            try writer.writeByte(4);
            try writer.writeAll(std.mem.asBytes(&addr.in.sa.addr));
            try writer.writeAll(std.mem.asBytes(&addr.in.sa.port));
        },
        // ...
    }
}
```

## 5. Safety and Validation

Following **TigerStyle**, we perform strict validation during deserialization:
*   **Bounds Checking**: We ensure the number of peers in a `FIND_NODE_RESPONSE` does not exceed $K=20$.
*   **Type Validation**: We verify that the `MessageType` is a valid enum value using `std.meta.intToEnum`.
*   **Memory Management**: The `Message` struct provides a `deinit` method to free any allocated payload data.

---

**Next Chapters:**
*   [Chapter 3: The Storage Layer](../storage/overview.md)
