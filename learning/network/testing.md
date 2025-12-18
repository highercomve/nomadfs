# Chapter 1.3: Testing Network Logic

Network code is notoriously difficult to test because it involves timing, external resources (sockets), and non-deterministic behavior.

To solve this, NomadFS uses **In-Memory Transport Mocks** found in `tests/network/memory_stream.zig`.

## 1. The `Pipe` Abstraction

A `Pipe` is a memory-backed transport that implements our `Stream` interface. It consists of two thread-safe buffers.

*   **`pipe.client()`**: Writing here puts data into Buffer A. Reading here takes data from Buffer B.
*   **`pipe.server()`**: Writing here puts data into Buffer B. Reading here takes data from Buffer A.

This allows us to simulate a full network connection between two components entirely within a single process.

## 2. Benefits of Memory Testing

1.  **Speed**: No system calls or network stack overhead. Thousands of handshakes per second.
2.  **Determinism**: No "flaky" tests caused by busy ports or local firewall rules.
3.  **Security Auditing**: We can inspect the "wire" (the memory buffer) to ensure that sensitive data (like plain text) is NOT present, verifying that our encryption layer is actually working.

### Example: Verifying Encryption
```zig
const pipe = Pipe.init(allocator);

// ... run Noise handshake over pipe ...

// Inspect the raw bytes on the 'wire'
const wire_data = pipe.buffer_a_to_b.items;
try std.testing.expect(std.mem.indexOf(u8, wire_data, "Secret Data") == null);
```

## 3. Integration Tests

While unit tests use `Pipe`, our integration tests (`tests/network/integration.zig`) use the actual `std.net` stack on the `loopback` (127.0.0.1) interface. This ensures that our abstractions correctly map to real operating system sockets.
