# Chapter 8.4: Performance Notes & Limits

No benchmarks are committed, so this chapter lists no throughput or latency
targets. It collects the constants in the code that bound size, memory and
time, and what they mean in practice.

## 1. Constants That Shape Performance

| What | Value | Where |
| :--- | :--- | :--- |
| Chunk size (FastCDC) | min 64 KiB, normal 256 KiB, max 1 MiB | `src/storage/chunker.zig` `Params` |
| Links per parent block | 174 (balanced tree) | `src/storage/dag/builder.zig` `MAX_LINKS` |
| File tree depth read by `tree.readAt` | ≤ 64 parent levels | `src/fs/tree.zig` `max_tree_depth` |
| Dir block size | ≤ 4 MiB encoded | `src/storage/dag/codec.zig` `max_dir_block_len` |
| Noise frame | ≤ 65,519 B plaintext + 16 B tag + 2 B length | `src/net/transport/noise.zig` `max_payload` |
| Yamux window | 1 MiB per stream | `src/net/transport/yamux.zig` `InitialWindowSize` |
| Yamux streams | ≤ 64 live per session (→ ≤ 64 MiB buffered) | `yamux.zig` `MaxStreams` |
| Handshake / connect bound | 10 s | `src/net/transport/tcp.zig` |
| Connection pool cap | ≤ 256 connections | `src/net/transport/manager.zig` `max_connections` |
| RPC handler cap | ≤ 256 concurrent handlers | `src/net/discovery/node.zig` `max_handlers` |
| Block store quota | configurable (`quota_mb`), 0 = unlimited | `src/config.zig`, `src/storage/engine.zig` |
| Read cache | `cache_mb`, default 2048 MiB, LRU by mtime, evicts to 90 % | `src/storage/engine.zig` |
| Idle connection reaped after | 5 min (checked every 10 s) | `src/net/transport/manager.zig` |
| K-bucket size / lookup parallelism | K = 20 / α = 3 | `src/net/discovery/kbucket.zig`, `lookup.zig` |
| Share rescan | every 30 s; unchanged size+mtime skipped | `src/fs/shares.zig`, `scan.zig` |
| Swarm manifest sync / backup round | every 10 s | `src/fs/swarm.zig` |
| Swarm manifest tombstone horizon | 90 days (7,776,000 s) | `src/fs/manifest.zig` `pruneTombstones` |
| Swarm manifest from a peer | ≤ 100,000 entries | `src/fs/manifest.zig` |
| FUSE max write / attribute cache | 128 KiB / 1 s | `src/fs/fuse.zig` |

## 2. What They Imply

- **Reading a range costs one block per tree level plus the leaf.** A file
  under 174 chunks (about 43 MiB at the average chunk size) needs the parent
  and one leaf. See [Merkle DAGs](../storage/dag.md).
- **Transport frame sizing.** Noise frames carry up to 65,519 bytes of payload
  plus framing and tag overhead, allowing bulk data transfers to saturate
  network links without excessive framing splits.
- **Requests are stream-per-RPC, blocks one at a time.** `GET_BLOCK` asks for
  one CID per stream, and the fetch paths (`Remote.load`, repair) request
  blocks sequentially, so a cold read over a high-latency link pays one round
  trip per block.
- **The FUSE loop is single-threaded**: one request at a time, so one slow
  remote fetch delays other operations on the mount.
- **One file per block.** The block store is a flat directory named by hex
  CID; a large store means many files in one directory, and every `get`
  re-hashes the block (SHA-256).
- **Shared files are re-hashed on every leaf read** (filestore), trading CPU
  for never serving stale bytes.
- **Threads, not an event loop.** Each accepted connection spawns a handshake
  thread, each connection a Yamux reader thread, and each incoming stream a
  handler thread. Thread count is bounded by connection caps (256) and RPC
  handler caps (256).

## 3. Cryptography Cost

The cipher is **ChaCha20-Poly1305**, which runs in software and needs no
AES-NI. Hashing uses BLAKE2s-256 (handshake, node and device IDs) and
SHA-256 (CIDs, on every block put, get and receive). Zig's `std.crypto` uses
whatever vector instructions the target allows; build with
`-Doptimize=ReleaseSafe` or `ReleaseFast` for representative numbers.

## 4. Operating Tips

- Raise `ulimit -n` on busy nodes: every connection and every block read
  holds a file descriptor for a while.
- Put `storage_path` on an SSD; block reads are small random reads.
- An always-on device with `swarm_backup = true` keeps swarm files readable
  when their authors are offline, and the copies are local reads for it.

## 5. Not Implemented Yet

Planned in [ROADMAP.md](../../ROADMAP.md) or obvious next steps, none present
today: parallel or pipelined block fetches, Yamux keep-alive PINGs for NAT
bindings, and a relay for devices that can't reach each other directly.

---

**Next:** [Chapter 9: API Reference](../api/reference.md) ·
[Back to the Internals Book](../README.md)
