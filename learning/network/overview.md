# Network Layer Overview: The "Pipe"

In NomadFS, the network layer is responsible for creating a secure, reliable, and multiplexed communication channel between peers. We call this the **"Pipe"**.

## 1. High-Level Architecture

The goal is to upgrade a raw, unreliable transport (like TCP) into a sophisticated peer-to-peer connection. We follow a layered approach:

```mermaid
graph TD
    App[Application Logic] --> Stream[Abstract Stream]
    Stream --> Yamux[Multiplexing Layer]
    Yamux --> Noise[Security Layer]
    Noise --> TCP[Transport Layer]
```

### The Layers
1.  **Transport (TCP)**: The raw byte-stream provided by the operating system.
2.  **Security (Noise)**: Wraps TCP to provide mutual authentication and encryption.
3.  **Multiplexing (Yamux)**: Splits the single encrypted connection into many logical "streams".
4.  **Interface (Abstract Stream)**: Provides a generic `Read/Write` interface to the rest of the application.

## 2. Abstractions (`mod.zig`)

To decouple the application from the underlying network implementation, we use two primary interfaces:

### `Connection`
Represents a session with a specific peer. It is authenticated and secure.
*   **Purpose**: A factory for streams.
*   **Methods**: `openStream()`, `acceptStream()`, `close()`.

### `Stream`
A bidirectional binary channel.
*   **Purpose**: The actual object used to send/receive data (e.g., for a DHT query or block transfer).
*   **Methods**: `read()`, `write()`, `close()`.

## 3. The Implementation Glue (`tcp.zig`)

The `tcp.zig` file manages the lifecycle of these connections:
*   **Listening**: Accepts raw TCP connections and immediately triggers the [Noise Handshake](./noise.md).
*   **Connecting**: Dials a remote peer and initiates the handshake.
*   **Session Management**: Once the handshake is complete, it starts the [Yamux Session](./yamux.md) in a dedicated background thread.

---

**Next Chapters:**
*   [Chapter 1.1: Security & The Noise Handshake](./noise.md)
*   [Chapter 1.2: Multiplexing with Yamux](./yamux.md)
*   [Chapter 1.3: Testing Network Logic](./testing.md)
