# Chapter 1.3: Testing Network Logic

Network code is hard to test: it depends on timing, sockets and threads.
NomadFS tests it at two levels: **in-memory pipes** for the protocol layers,
and **multi-node tests on loopback TCP** for the whole stack. All of these
live in `tests/` and run as part of `zig build test` (see the
[Testing Strategy](../../testing.md) chapter for the build steps).

## 1. The `Pipe` Abstraction (`tests/network/memory_stream.zig`)

`Pipe` is a memory-backed duplex connection that implements
`network.Stream`. It holds two buffers guarded by one mutex and condition
variable:

*   **`pipe.client()`** writes into `buffer_a_to_b` and reads from
    `buffer_b_to_a`.
*   **`pipe.server()`** does the opposite.

Reads block until data arrives. A whole Noise handshake, or a Yamux session,
can run between two threads of one test process. (`MemoryStream`, in the
same file, is a simpler one-way buffer.)

## 2. Benefits of Memory Testing

1.  **Speed**: no sockets and no system network stack.
2.  **Determinism**: no busy ports or firewall rules.
3.  **Inspection**: the test can read the "wire" directly. It can check that
    plaintext never appears on it.

### Example: verifying encryption (`tests/network/security_test.zig`)
```zig
var pipe = Pipe.init(allocator);
defer pipe.deinit();
// ... client thread and server run a Noise handshake over the pipe,
//     then exchange "Super Secret Plaintext" and "Server Reply" ...
const wire_data_1 = pipe.buffer_a_to_b.items;
try std.testing.expect(std.mem.indexOf(u8, wire_data_1, "Super Secret Plaintext") == null);
```

## 3. What the Network Tests Cover

| File | Covers |
| :--- | :--- |
| `tests/network/security_test.zig` | handshake and data transfer; a wrong swarm key fails; a connection dropped mid-handshake; data on the wire is encrypted; a silent peer can't stall the handshake or shutdown; the device hello binds both identities; strict trust policy rejects unknown devices; a paired device's transport key must match |
| `tests/network/yamux_test.zig` | several streams over one connection; invalid frame types close the session; frames larger than the window are rejected before allocating; streams beyond `MaxStreams` are reset; streams are freed once both sides close; read deadlines |
| `tests/network/yamux_flow_control_test.zig` | a 300 KB write against the 256 KiB window, with a slow reader |
| `tests/network/manager_test.zig` | the reaper retires connections; failed registration leaves the reference with the caller; connections in use are not reaped as idle |
| `tests/network/mdns_test.zig` | two `MDNS` instances on UDP 5354 find each other (waits up to 15 s) |
| `tests/network/integration.zig` | a TCP loopback round trip |

Many source files also carry their own unit tests (for example the key-file
test in `noise.zig` and the packet parser tests in `mdns.zig`). `zig build
test` runs those too.

## 4. Multi-Node Simulations

DHT behavior needs more than two peers. `TestPeer` (`tests/helpers.zig`)
wraps a config and a `ConnectionManager` with a fresh key, listening on
`127.0.0.1:<port>` with UPnP and LAN announcements turned off.

*   **Discovery** (`tests/dht/discovery_test.zig`): **5** nodes on ports
    11000 and up. Node 0 knows every other node; the last node knows only
    node 0, and must find another node by an iterative lookup through it.
    The test is named "X-node discovery"; its log line still says
    "10-node".
*   **Churn** (`tests/dht/churn_test.zig`): **5** nodes. The node closest to
    a target is stopped, and a lookup must route around it.
*   Other DHT tests cover `PING`/`PONG`, `STORE`/`FIND_VALUE`, RPC
    serialization, lookup state, bucket refresh, and authentication (a
    spoofed `PING` sender is rejected; dialing with the wrong expected node ID
    fails; an RPC to a silent peer times out; a connect to an unreachable
    address is bounded).

These tests use the real TCP stack, so Noise, Yamux and the DHT logic run
together as they do in a node.

---

**Next Chapters:**
*   [Chapter 1.4: Connection Management](./management.md)
