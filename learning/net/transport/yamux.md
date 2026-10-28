# Chapter 1.2: Multiplexing with Yamux

Two devices often need several exchanges at once: a block transfer, a
directory listing, a `PING`. Opening a new TCP connection and Noise handshake
for each would be slow. Instead NomadFS runs many logical **streams** over
one encrypted connection, using
[Yamux](https://github.com/hashicorp/yamux/blob/master/spec.md), implemented
in `src/net/transport/yamux.zig`.

> Diagram and plain-language walkthrough:
> [Learn: Yamux](https://nomadfs.foreachdeveloper.com/learn/yamux/).

## 1. The Anatomy of a Frame

Every frame starts with a **12-byte header**, big-endian, followed by
`length` bytes of payload for `DATA` frames:

```zig
pub const Header = struct {
    version: u8 = Version, // always 0
    type: Type,            // DATA, WINDOW_UPDATE, PING, GO_AWAY
    flags: u16,            // SYN, ACK, FIN, RST
    stream_id: u32,
    length: u32,           // payload bytes (DATA) or window credit (WINDOW_UPDATE)
};
```

`Header.decode` rejects any version other than 0 and any type above
`GO_AWAY` with `error.InvalidFrame`. The session then shuts down rather than
casting garbage into the enum.

### Frame Types
*   **`DATA` (0)**: payload for a stream. Also opens a stream (with `SYN`).
*   **`WINDOW_UPDATE` (1)**: grants the sender `length` more bytes of window
    (see section 3). Can also carry `FIN`/`RST`.
*   **`PING` (2)**: echoed back with `ACK` set.
*   **`GO_AWAY` (3)**: the peer will accept no new streams.

### Flags
*   **`SYN` (1)**: opens a stream.
*   **`ACK` (2)**: set only on the reply to a `PING`. NomadFS does **not** send
    `ACK` when it accepts a stream; a stream is usable as soon as `SYN` is sent.
*   **`FIN` (4)**: half-close: "I will send no more on this stream."
*   **`RST` (8)**: abort the stream.

Yamux frames are written into the [Noise stream](./noise.md), which seals
them in encrypted frames of at most 65,535 bytes (with up to 65,519 bytes
plaintext payload). A large `DATA` frame can span multiple frames.

## 2. Streams

### Stream IDs
`Session.init(allocator, transport, is_server)` sets `next_stream_id` to `1`
for the side that **dialed** the TCP connection and `2` for the side that
**accepted** it (`tcp.zig` passes `is_server = !initiator`). Each new stream
adds 2, so dialer streams are odd and listener streams are even, and the two
never collide. `error.StreamIdsExhausted` is returned near `maxInt(u32)`.

### Opening (`Session.newStream`)
1. Before allocating, `Session.reapClosed` cleans up any expired half-closed
   streams.
2. Under the session mutex, refuse if the session is closed or the peer sent
   `GO_AWAY` (`error.SessionClosed`), or if active streams reach `MaxStreams = 64`
   (or total allocated streams reach `MaxStreams * 2`).
3. Register a `YamuxStream` with both windows at `InitialWindowSize`
   (1 MiB).
4. Send `DATA` with `SYN` and length 0.

On the other side, `run()` (`dataTarget`) sees a `SYN` for an unknown ID
of the peer's parity and, if active streams are under `MaxStreams`, puts the new
stream on `accept_queue`. `Session.acceptStream()` blocks until one is there.
Past the limit, the payload is discarded and the stream is refused with a
`WINDOW_UPDATE` frame carrying `RST`. Frames for an ID that isn't open
(without `SYN`, or with the wrong parity) are read and dropped.

### Closing and Half-Close Maintenance (`streamClose`)
The local user calls `streamClose` when done sending:
1. It sets `local_closed = true`, records `closed_at_ms = sync.monotonicMillis()`,
   and immediately frees unread incoming data (`incoming_data.clearAndFree`),
   releasing memory promptly.
2. It sends `FIN` (unless the stream was already reset).
3. A `FIN` or `RST` from the peer sets `remote_closed` (`RST` also sets `reset`).
4. **Half-close cleanup**: If the remote peer stops responding or fails to send
   a closing `FIN`/`RST`, half-closed streams are garbage-collected by
   `reapClosed` after `close_timeout_ms = 30_000` (30 seconds). Reaped streams
   are destroyed and a `RST` frame is sent to the peer.
5. **Reader protection**: While a `DATA` payload is actively being read off the
   wire, `reader_active` protects the stream from being prematurely destroyed.
6. The session frees a stream once both sides have closed it and no reader is
   active, or on `deinit`. The user must not touch a stream after closing it.

## 3. Flow Control: The Window System

Each `YamuxStream` tracks two windows, both starting at **1 MiB**
(`InitialWindowSize = 1024 * 1024`):

1.  **Sending** (`streamWrite`): sends at most `remote_window` bytes per
    `DATA` frame and decrements it. At 0 the writer waits on `write_cond`,
    honoring the stream's deadline if one is set (`error.Timeout`).
2.  **Receiving** (`run`): a `DATA` frame longer than the stream's
    `local_window` is a protocol error (`error.WindowExceeded`). This is
    checked *before* the payload is read, so a peer can never make us buffer
    more than 1 MiB per stream. The payload is appended to `incoming_data`.
3.  **Crediting** (`streamRead`): after the application reads `n` bytes,
    `local_window += n` and a `WINDOW_UPDATE` with `length = n` goes out
    (batched in half-window increments).
4.  **Waking**: a received `WINDOW_UPDATE` adds to `remote_window`
    (`error.WindowOverflow` if that would overflow a u32) and signals waiting
    writers.

With `MaxStreams = 64` and a 1 MiB window, a session caps buffered receive
data at **64 MiB**.

## 4. The Session Loop: `run()`

`establish()` in `tcp.zig` spawns one thread per connection running
`Session.run()`. It reads a 12-byte header from the Noise stream, then:

*   **`DATA`**: opens a stream on `SYN`, enforces the window, reads the
    payload into `incoming_data` while guarding with `reader_active`, wakes
    readers on `cond`, and handles `FIN`/`RST`. Data for an unknown or closed
    stream is read and discarded.
*   **`WINDOW_UPDATE`**: credits `remote_window` and wakes writers; handles
    `FIN`/`RST`.
*   **`PING`**: if `ACK` isn't set, writes the same header back with `ACK`
    added. A `PING` with `ACK` is ignored (there is no RTT tracker).
*   **`GO_AWAY`**: sets `go_away` and wakes `acceptStream` waiters. New
    `newStream` calls fail, and **existing streams keep working**.

When the transport fails or a frame is invalid, the session closes. Every
stream is marked reset, and all waiters are woken.

## 5. Thread Safety

*   **Lock order**: `Session.mutex` before `YamuxStream.mutex`.
*   **`Session.write_mutex`** serializes frame writes. It is only taken with no
    other lock held, so a blocked socket write never stalls frame dispatch.
*   **Dynamic write buffer maintenance**: after serializing large frame writes,
    the write buffer shrinks if its capacity exceeds 128 KiB to prevent lingering
    allocation bloat.
*   Readers and writers wait on per-stream condition variables (`cond`,
    `write_cond`). `streamSetTimeout` bounds each wait.
*   Received data is stored in `incoming_data` and compacted once more than
    4 KiB has been consumed.

## 6. How NomadFS Uses Streams

Each RPC uses **one stream**. The caller opens it, writes one request,
reads one reply and closes it (see [Chapter 2.4](../discovery/rpc.md)). On
the receiving side `discovery.Node.serve` loops on `acceptStream()` and
handles each stream on its own thread with a 10-second timeout. A slow
`GET_BLOCK` doesn't delay a `PING` on the same connection.

## 7. Not implemented yet

Nothing in NomadFS *sends* `PING` or `GO_AWAY` frames today. Connections
close by shutting down the socket. [ROADMAP.md](../../../ROADMAP.md) plans
Yamux `PING` keep-alives to hold NAT mappings open on roaming devices.

---

**Next Chapters:**
*   [Chapter 1.3: Testing Network Logic](./testing.md)
*   [Chapter 1.4: Connection Management](./management.md)
