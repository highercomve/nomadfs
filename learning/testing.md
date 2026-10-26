# Testing Strategy

Reliability is paramount for a file system. NomadFS employs a multi-layered testing strategy.

## 1. Unit Tests (`zig build test-mod`)

- **Scope**: Individual functions and modules in isolation.
- **Focus**: Logic verification, edge cases, algorithmic correctness.
- **Example**: Verifying that the XOR metric correctly calculates distances between NodeIDs.

## 2. Integration Tests (`zig build test-int`)

- **Scope**: Interaction between multiple modules (e.g., Transport + DHT).
- **Focus**: Protocol flows, timing issues, state machine transitions.
- **Tooling**: Uses `TestPeer` to spawn in-process nodes.
- **Example**: Spinning up 5 nodes and ensuring `FIND_NODE` returns the correct peers.

## 3. Network Simulation (In-Memory)

- **Scope**: Full network stack but over memory pipes.
- **Benefits**:
    - **Deterministic**: No network flake.
    - **Fast**: Thousands of interactions per second.
    - **Deep Inspection**: Can introspect "wire" buffers.
- **See**: [Chapter 1.3: Testing Network Logic](./net/transport/testing.md).

## 4. End-to-End Tests (Docker)

- **Scope**: Full binaries running in Docker containers.
- **Focus**: CLI usage, configuration parsing, interoperability, OS-level issues.
- **CI/CD**: Ran on every commit via GitHub Actions (future).

## 5. TigerStyle & Safety

We leverage Zig's safety features:
- **Debug Builds**: Enable runtime safety checks (overflow, bounds checking, use-after-free).
- **Leak Detection**: The General Purpose Allocator (GPA) reports memory leaks on shutdown.
- **Fuzzing**: (Planned) Using `zig fuzz` to test parsers and protocol handlers.

## 6. How to Run Tests

```bash
# Run all tests
zig build test

# Run only specific filters
zig build test -- --test-filter "dht"
```
