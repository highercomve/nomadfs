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

## 4. The Session Loop: `run()`

Each connection runs a background thread executing the `Session.run()` function. This is the "heart" of the multiplexer.

### The Routing Logic
1.  **Read Header**: The loop reads exactly 12 bytes from the underlying encrypted Noise channel.
2.  **Handle Frame Type**:
    *   **`DATA`**: It looks up the `stream_id` and appends the payload to that stream's `incoming_data` buffer. If it's a new `SYN`, it accepts the new stream.
    *   **`WINDOW_UPDATE`**: It updates the `remote_window` for the stream and wakes up any blocked writers.
    *   **`PING`**: It immediately replies with a PONG (see below).
    *   **`GO_AWAY`**: It marks the session as closed.
3.  **Signal**: It signals a **Condition Variable** (`cond`) associated with the stream to wake up app threads.

## 5. Control Messages

Beyond simple data transfer, Yamux uses control frames to maintain the health of the connection.

### PING / PONG
A `PING` frame (Type 2) is used to measure latency (RTT) or verify the peer is still alive.
*   **Request:** Sender sends `PING` with `flags = 0`.
*   **Response:** Receiver must immediately send back a `PING` with `flags = ACK` and the exact same payload/length (usually empty or an opaque session ID).
*   **NomadFS Handling:** The session loop detects the Ping request and immediately writes the Ping ACK back to the transport layer, ensuring the connection remains active without application intervention.

### GO_AWAY
A `GO_AWAY` frame (Type 3) signals a graceful shutdown.
*   **Trigger:** A peer wants to close the connection but let existing streams finish (e.g., shutting down the app).
*   **Action:** The receiver marks the session as `closed`.
*   **Effect:** No *new* streams can be opened (attempts will fail), but existing streams continue processing until they naturally complete.

## 6. Thread Safety & Concurrency

NomadFS's Yamux implementation is designed for high concurrency:
*   **Session Mutex**: Protects the hash map of streams and the outbound transport.
*   **Stream Mutex**: Protects the `incoming_data` buffer for a specific stream.
*   **Zero-Copy (Aspiration)**: While the current implementation copies data into buffers, the design allows for future optimization to minimize memory overhead during high-speed transfers.

By separating the **Network I/O** (the background loop) from the **Application Logic** (the reader/writer threads), NomadFS ensures that a slow file transfer doesn't block critical DHT discovery queries.

## 7. Implementation Note: Evolution from MVP

Implementing a multiplexer is complex. Our initial MVP focused solely on data movement.

*   **MVP Behavior**: The `Session.run()` loop only processed `DATA` and `WINDOW_UPDATE` frames. `PING` and `GO_AWAY` frames were ignored (discarded).
*   **The Flaw**:
    *   **Timeouts**: Without responding to Pings, remote peers would assume we crashed and sever the connection, even if we were just idle.
    *   **Errors**: Without `GO_AWAY`, a peer shutting down would sever the TCP connection, causing "Connection Reset" errors for active streams instead of a clean "End of Stream".
*   **The Fix**: Adding handlers for these control frames allows NomadFS to "play nice" with the network. We now prove our liveness (via Pongs) and respect peer shutdowns, creating a robust, long-running mesh.
