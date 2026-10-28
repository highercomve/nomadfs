# Chapter 3.1: Chunking & Blocks

The smallest unit of storage in NomadFS is the **Block**: some bytes and the hash that names them. This chapter covers the `Block` type and how files are cut into chunks. The concept is explained with diagrams on the website: [FastCDC](https://nomadfs.foreachdeveloper.com/learn/fastcdc/).

## 1. The `Block` Structure

`src/storage/block.zig`:

```zig
pub const Block = struct {
    cid: [32]u8, // SHA-256 hash of `data`
    data: []const u8,

    pub fn new(data: []const u8) Block; // hashes data with SHA-256
};
```

`data` is the **encoded** block: a one-byte tag followed by the body (see [Chapter 3.2](./dag.md)). A `Block` does not own its bytes; the slice belongs to the caller.

The same file also holds an old fixed-size `Chunker.chunk(data, chunk_size, allocator)`. Only its own test calls it; nothing in the node uses it. Real chunking is FastCDC, below.

## 2. Content Addressing

The CID is `SHA-256(data)`, where `data` is the encoded block. For a file chunk that means

```text
CID = SHA-256( 0x00 ‖ chunk bytes )
```

so a chunk's CID is **not** what `sha256sum` prints for the chunk alone. The tag is hashed with the content so that a block's kind is part of its name and a block from a peer can be decoded without outside type information.

What you get from naming blocks by hash:
*   **Integrity**: `StorageEngine.put` and `get` re-hash and refuse mismatches ([Chapter 3.3](./engine.md)). A block from a peer that doesn't hash to the requested CID is never stored.
*   **Deduplication**: identical chunks have one CID and are stored once.
*   **Any source will do**: since the bytes can be checked, a block can be fetched from any device that has it.

More on this: [SHA-256 and content addressing](https://nomadfs.foreachdeveloper.com/learn/sha-256/).

## 3. Chunking Strategy: FastCDC

The `Chunker` in `src/storage/chunker.zig` implements **FastCDC** (Xia et al., USENIX ATC 2016): content-defined chunking driven by a gear hash.

```zig
pub const Params = struct {
    min_size: usize = 64 * 1024,
    avg_size: usize = 256 * 1024,
    max_size: usize = 1024 * 1024,
};
```

`cut(params, data)` returns the length of the next chunk:

1.  If `data.len <= min_size`, the whole rest is one chunk. Otherwise hashing starts at `min_size`, so no chunk (except the last) is smaller than 64 KiB.
2.  For each byte: `hash = (hash << 1) +% gear[data[i]]`. The shift pushes old bytes out of the 64-bit state, so the hash depends only on the last 64 bytes.
3.  Before `avg_size` the chunker cuts where `hash & mask_s == 0`; `mask_s` has `log2(avg) + 2` = 20 high bits set (a match about once per 2²⁰ bytes). From `avg_size` on it uses `mask_l` with `log2(avg) − 2` = 16 bits, which matches far more often. This is FastCDC's *normalized chunking*: sizes cluster around 256 KiB.
4.  If no cut is found by `max_size` (1 MiB), cut there.

```zig
// Inner loop, simplified
hash = (hash << 1) +% gear[data[i]];
if (hash & mask_s == 0) return i + 1; // before avg_size; mask_l after
```

The 256-entry `gear` table is generated at **compile time** by SplitMix64 from the fixed seed `0x123456789abcdef0`. `Params.validate()` asserts `min < avg < max` and that `avg` is a power of two.

### Why not fixed-size?
With fixed 256 KiB chunks, inserting one byte near the start of a file shifts every later boundary. Every chunk after the edit gets a new CID, and a peer that had the old version has to fetch almost the whole file again. Content-defined boundaries resynchronise right after the edit, so an insertion changes only the chunk it lands in (occasionally a neighbour too), and the rest of the file shares its blocks with the old version.

The trade-off is that blocks are no longer aligned to file offsets. That is why parent links in the DAG carry explicit sizes instead of assuming a fixed chunk size.

## 4. Why 64 KiB / 256 KiB / 1 MiB?

The bounds balance three competing needs:
1.  **Deduplication**: smaller chunks find more shared data but make bigger DAGs.
2.  **Network**: each block is one `GET_BLOCK` request, so bigger chunks mean fewer round trips; smaller ones mean less wasted transfer when only a few bytes are needed.
3.  **Bounded memory**: the chunker holds at most one maximum-size chunk, so the limit is also the streaming buffer size.

The gear table, seed and parameters are part of the storage format: change any of them and the same file chunks differently, so every CID changes. They are constants (`storage.dag.builder.chunk_params = chunker.Params{}`), not configuration.

## 5. Memory Efficiency

*   **Streaming**: `Chunker.next(reader)` reads into one `max_size` (1 MiB) buffer, compacts the unconsumed tail to the front, and returns a slice into that buffer, valid until the next call.
*   **One copy**: `DagBuilder.build` copies each chunk once into a reused buffer whose byte 0 is the leaf tag, hashes it, and persists it (or hands its location to the filestore, see [Chapter 3.2](./dag.md)). The whole file is never in memory.
*   **Only CIDs are kept**: the builder keeps each leaf's CID and size, not its data, to build the parent layers.
*   **Determinism**: boundaries depend only on the content, not on how the reader delivers bytes (`test "Chunker determinism across different read chunk sizes"`), so two devices chunking the same file get the same CIDs.

---

**Next Chapters:**
*   [Chapter 3.2: Building the Merkle DAG](./dag.md)
*   [Chapter 3.3: The Disk Engine](./engine.md)
