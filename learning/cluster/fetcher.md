# Chapter 4.1: The Fetcher (`src/cluster/fetcher.zig`)

Every block a read needs from another device comes through `Fetcher.fetch`: the mount, the app's
viewer and downloads, Browse, the swarm folder, folder backup and the keeper. Callers say *which*
block of *which* file and *who may hold it*; the fetcher decides *where from*.

```zig
pub fn fetch(self: *Fetcher, root: *const Cid, cid: *const Cid,
             holders: []const NodeID, allocator: std.mem.Allocator) ![]u8
```

1. The local store first (kept blocks, the read cache, shared files through the filestore).
2. Else the best holder that hasn't been tried for this block, isn't backing off and hasn't missed
   this block or file (below). On "not found" or an error, the next one.
3. The bytes are verified against the CID and kept in the read cache (`putCached`); the caller
   pins them when they must be kept (the keeper).

## 1. Picking a holder

For each candidate: `cost = (requests in flight + 1) / rate`, the expected wait for one more block.
The least cost wins; ties keep the caller's order (the author, the sharing device first).

* `rate` is an EWMA (3/4 old, 1/4 new) of bytes per millisecond, measured on **leaf blocks of at
  least 16 KiB only**: small index blocks measure round-trip time, not throughput.
* A device never measured counts as fast as the best one known (or 4 MB/s), so new holders get
  tried.

A single fetch asks one holder at a time. The spreading comes from the callers: read-ahead runs
six workers and the keeper four per copy, so six blocks in flight go to the holders in proportion
to their speed. A stalled holder accumulates requests in flight, its cost rises, and the others get
the work. No message is sent that the read didn't need.

### Multi-device parallel pulling

When a file (such as a camera photo `PXL_...RAW-01.MP.jpg` taken on a phone and backed up to a
home server) is read by another node (such as a laptop), `holdersOf()` identifies both the
author (`Phone`) and the backup peer (`Home Server`) as candidate holders.

Because read-ahead issues requests for upcoming blocks concurrently across 6 worker threads, the
fetcher dispatches them in parallel across Yamux streams. Both nodes serve chunks simultaneously,
with the faster link carrying the majority of the transfer:

```mermaid
sequenceDiagram
    participant C as Laptop (Reader, 6 workers)
    participant F as Fetcher
    participant S as Home Server (LAN backup, fast)
    participant P as Phone (Wi-Fi author, slower)
    C->>F: blocks 1..6 of PXL_photo.jpg
    F->>S: GET_BLOCK 1
    F->>P: GET_BLOCK 2
    F->>S: GET_BLOCK 3
    S-->>F: block 1 (rate 45 MB/s ↑)
    F->>S: GET_BLOCK 4
    P-->>F: block 2 (rate 15 MB/s)
    F->>P: GET_BLOCK 5
    S-->>F: block 3
    F->>S: GET_BLOCK 6
    Note over F: chunks pulled in parallel; faster server takes more blocks
```

## 2. What it remembers (bounded)

| Table | Size | Entry | Effect |
| :--- | :--- | :--- | :--- |
| devices | 64, least recently used out | rate, in flight, failures, back-off until, blocks and bytes served | picking; measuring (`snapshot`, `totals`) |
| block misses | 512, a ring | (device, block) for 30 s | a holder that said "not found" isn't asked for that block again soon |
| file misses | 128 | (device, file, count) for 60 s | after 3 misses in a row on a file, the device is skipped for the whole file; a block it serves resets the count |

A device that fails to connect backs off 5 s, doubling up to 60 s. So a device without a file costs
a few round trips, not one per block, and a backup still catching up isn't hidden for long.

## 3. The network side

The fetcher doesn't open connections itself: `BlockManager` gives it a `Transport` that sends one
`GET_BLOCK`. It uses a live connection or the routing table's addresses; a holder not met yet (a node
that just started may know the relay but not the file's author) is looked up through the DHT once,
and backs off if it can't be reached. The tests give it a fake transport instead, with chosen delays.

## 4. Measured

A 99 MiB video read cold on four devices (October 2026, home Wi-Fi and a cloud relay):

| Reader | Holders | MiB/s | Blocks from |
| :--- | :--- | ---: | :--- |
| desktop | home server | 27.1 | server 361 |
| phone | server, desktop (read cache) | 15.9 | desktop 252, server 109 |
| cloud relay | server, desktop | 6.3 | server 357, desktop 4 |

The faster holder got most of the work each time. On one LAN a single holder can already fill the
link, so spreading doesn't make a read faster there; it keeps a read going when a holder is slow,
busy or gone. About 1 % more bytes travel than the file itself. `nomadfs --bench-read` and
`scripts/bench-devices.sh` measure it ([Observability](../ops/observability.md)).

---

**Next:** [Chapter 4.2: Holders](./holders.md)
