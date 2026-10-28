# Chapter 11: Testing

NomadFS is tested with Zig's built-in test runner at three levels: unit tests
next to the code, an in-process integration suite under `tests/`, and
separate harnesses for the mobile bindings.

## 1. Build Steps (`build.zig`)

| Command | Runs |
| :--- | :--- |
| `zig build test` | All three below, **in sequence**: module → executable → integration |
| `zig build test-mod` | `test` blocks reachable from `src/root.zig` (the `nomadfs` module) |
| `zig build test-exe` | `test` blocks reachable from `src/main.zig` |
| `zig build test-int` | `tests/runner.zig` (integration suite) |

The steps are chained on purpose (`run_exe_tests` depends on
`run_mod_tests`, integration on both): several tests bind real TCP ports on
localhost and would collide if run in parallel.

**There is no test filter.** `build.zig` doesn't pass `b.args` to the test
artifacts or set `filters`, so `zig build test -- --test-filter "dht"` runs
everything. To narrow a run, use the step that covers the code
(`test-int`, `test-mod`), or run one file directly, e.g.
`zig test src/storage/chunker.zig` for a self-contained file.

## 2. Unit Tests (`src/`)

Every source file carries its own `test` blocks, and `src/root.zig` imports
every module in a final `test { … }` block so none is skipped (including
modules nothing else imports yet, such as `cluster/vectors.zig` and
`metrics.zig`). Examples of what they pin down:

- `storage/chunker.zig`: chunks reassemble to the input and cut points don't
  depend on how the reader hands over the bytes;
- `storage/dag/codec.zig`: malformed, truncated or unsorted blocks are
  rejected;
- `fs/tree.zig`: scan a folder, list it, read ranges across leaf boundaries,
  rescans reproduce the same root;
- `fs/manifest.zig`: concurrent edits keep both identically on both sides,
  an edit beats a concurrent delete, conflict names, unsafe peer paths;
- `device/*`: ticket canonical form and signatures, trust-store signing,
  hello binding, rotation acceptance rules;
- `net/transport/noise.zig`: key files are `0600` and never overwritten.

Tests use `std.testing.allocator`, which fails a test on any leak.

## 3. Integration Suite (`tests/`)

`tests/runner.zig` imports every suite; `tests/helpers.zig` provides
`TestPeer` (an in-process node on a given port). The nodes run in one
process and talk over real loopback TCP with the full Noise + Yamux stack.

| Directory | Files | Covers |
| :--- | :--- | :--- |
| `tests/network/` | `integration`, `security`, `manager`, `mdns`, `yamux`, `yamux_flow_control` | TCP loopback, handshake failures (wrong swarm key, dropped or silent peers), identity binding and transport-key pinning, connection manager, LAN announcements, Yamux streams and windows |
| `tests/dht/` | `lookup`, `rpc`, `ping`, `store`, `discovery`, `churn`, `kbucket_standard`, `auth` | RPC encoding, PING identity checks, iterative lookups (5-node discovery and churn), k-bucket rules, device auth over the wire |
| `tests/cluster/` | `transfer`, `revocation`, `share`, `swarm`, `rotation`, `swarm_backup` | put/get across nodes, revocation propagation, browsing shares, swarm folder sync and conflicts, key rotation, backup devices |

`tests/network/memory_stream.zig` is an in-memory `Stream` used for
deterministic Noise/Yamux tests without sockets. `tests/dht/ping_test_main.zig`
is not imported by the runner.

## 4. Mobile Bindings

These are run by hand, outside `zig build test`
([Chapter 10](./mobile/api.md)):

- `cd src/mobile && swift test`: a two-node put/get round trip through the
  Swift package and the real library;
- `src/mobile/android/emulator/harness.sh`: builds a debug APK, installs it
  on an emulator or phone, and runs a two-node transfer through the Java
  binding;
- `src/mobile/testing/host-probe.c`: a desktop C client for cross-device
  transfers.

## 5. What Is Not There

- **CI**: the only GitHub workflow (`.github/workflows/site.yml`) builds and
  deploys the website. Tests are run locally.
- **Docker end-to-end tests**: none. The `Dockerfile` only packages the
  binary, and still pins Zig 0.15.2 ([Chapter 8.1](./ops/deployment.md)).
- **Fuzzing**: not set up. The parsers that take network input
  (`codec.decode`, `rpc.Message.deserialize`, manifest JSON, tickets) are the
  natural first targets.
- **FUSE**: the mount has no integration test; it is exercised by hand.

---

[Back to the Internals Book](./README.md)
