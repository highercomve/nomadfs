# Chapter 1.2: Multiplexing with Yamux

In a distributed system, we often need to perform multiple concurrent operations with a single peer. For example, we might be downloading a file chunk while simultaneously sending a "Ping" to check if the peer is still alive.

Instead of opening multiple TCP/Noise connections (which is slow and expensive), we use **Yamux** to run many logical **Streams** over a single authenticated pipe.

## 1. The Anatomy of a Frame

Yamux is a stream-oriented multiplexing protocol. It breaks data into small chunks called **Frames**. Every frame starts with a **12-byte header**, followed by an optional variable-length payload.

### The Header Structure
```zig
pub const Header = struct {
    version: u8,    // Always 0 in NomadFS
    type: Type,     // The purpose of this frame
    flags: u16,     // Control bits (SYN, ACK, FIN, RST)
    stream_id: u32, // The logical stream this belongs to
    length: u32,    // Length of the following payload
};
```

### Frame Types
*   **`DATA` (0)**: Used to transmit actual application data.
*   **`WINDOW_UPDATE` (1)**: Used to manage flow control (see section 3).
*   **`PING` (2)**: Used to measure Round Trip Time (RTT) and keep the connection alive.
*   **`GO_AWAY` (3)**: Used to signal that the entire session is shutting down.

## 2. Stream Lifecycle & Flags

Yamux uses flags to manage the state of each logical stream.

### Stream ID Allocation
To prevent conflicts where both sides try to use the same ID:
*   The **Initiator** (who started the TCP connection) uses **odd IDs** (1, 3, 5...).
*   The **Responder** (who accepted the TCP connection) uses **even IDs** (2, 4, 6...).

### The Flags
*   **`SYN` (1)**: "Synchronize". Sent to initiate a new stream.
*   **`ACK` (2)**: "Acknowledge". Sent in response to a `SYN` to confirm the stream is open.
*   **`FIN` (4)**: "Finish". Sent to perform a "graceful close". It tells the peer: "I will not send any more data on this stream."
*   **`RST` (8)**: "Reset". Sent to perform an "abrupt close". Usually indicates an error condition.

### Opening a Stream
1.  **Client** calls `openStream()`, picks ID `3`, and sends a `DATA` frame with the `SYN` flag.
2.  **Server** receives the `SYN` frame, creates a local `YamuxStream` object for ID `3`, and places it in the `accept_queue`.
3.  **Server** typically responds with an `ACK` flag (optional in some implementations, but good practice).

## 3. Flow Control: The Window System

In a decentralized network, nodes have vastly different capabilities. A high-speed server could easily overwhelm a mobile device's memory if it sends data faster than the app can process it. Yamux prevents this using **Flow Control Windows**.

1.  **Initial Window**: Each stream starts with a **256 KB** window on both sides.
2.  **Sender Constraint**: The sender tracks the `remote_window`. Every byte sent decreases this count. If it hits **0**, the sender's `write()` call blocks.
3.  **Receiver Feedback**: When the receiver's application consumes data via `read()`, it frees up space in its local buffer. It then sends a `WINDOW_UPDATE` frame back to the sender.
4.  **Wake up**: Upon receiving the update, the sender increases its `remote_window` and signals the blocked writer thread to continue.

This mechanism ensures that NomadFS remains stable even when transferring large files between nodes with asymmetric bandwidth.

## 4. Graceful Closure: The FIN Flag

When an application is finished with a stream, it calls `close()`.
1.  The local `YamuxStream` is marked as `closed`.
2.  A 0-length `DATA` frame with the `FIN` flag is sent to the peer.
3.  The peer receives the `FIN` flag and marks its own side as `closed`.
4.  Subsequent `read()` calls on a closed stream will return the remaining buffered data and then return `0` (EOF).

This allow us to distinguish between a clean "End of File" and an abrupt connection failure.

## 4. The Session Loop: `run()`

Each connection runs a background thread executing the `Session.run()` function. This is the "heart" of the multiplexer.

### The Routing Logic
1.  **Read Header**: The loop reads exactly 12 bytes from the underlying encrypted Noise channel.
2.  **Lookup**: It looks up the `stream_id` in a hash map (`streams`).
3.  **Handle Data**:
    *   If the frame is `DATA` and the stream exists, it appends the payload to that stream's `incoming_data` buffer.
    *   If it's a new `SYN` frame, it creates a new stream and signals the `accept_cond` variable.
4.  **Signal**: It signals a **Condition Variable** (`cond`) associated with the stream. Any thread waiting in a `stream.read()` call will wake up and process the new data.

## 5. Thread Safety & Concurrency

NomadFS's Yamux implementation is designed for high concurrency:
*   **Session Mutex**: Protects the hash map of streams and the outbound transport.
*   **Stream Mutex**: Protects the `incoming_data` buffer for a specific stream.
*   **Zero-Copy (Aspiration)**: While the current implementation copies data into buffers, the design allows for future optimization to minimize memory overhead during high-speed transfers.

By separating the **Network I/O** (the background loop) from the **Application Logic** (the reader/writer threads), NomadFS ensures that a slow file transfer doesn't block critical DHT discovery queries.

