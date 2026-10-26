# Chapter 3.1: Chunking & Blocks

In NomadFS, data is stored as a collection of immutable, content-addressed **Blocks**. This chapter explains how raw data is transformed into these blocks.

## 1. The `Block` Structure

A `Block` is the atomic unit of storage in NomadFS. It consists of two parts:
1.  **CID (Content Identifier)**: A 32-byte SHA-256 hash of the data.
2.  **Data**: The raw bytes of the chunk.

```zig
pub const Block = struct {
    cid: [32]u8,
    data: []const u8,
};
```

## 2. Content Addressing

The CID is derived directly from the data. This means:
*   **Integrity**: If a single bit of the data changes, the CID changes.
*   **Deduplication**: If two files contain the same chunk of data (same content-defined boundary and bytes), that chunk is only stored once, as both share the same CID.

## 3. Chunking Strategy: FastCDC

A large file must be split into multiple blocks. The component responsible for this is the `Chunker` in `src/storage/chunker.zig`, which implements **FastCDC** (Xia et al., USENIX ATC 2016): content-defined chunking driven by a gear hash over a 256-entry table that is generated at compile time from a fixed seed.

Chunk boundaries are chosen by the content itself:

```zig
// A rolling hash skips ahead; a boundary is where the mask matches.
hash = (hash << 1) +% gear[data[i]];
if (hash & mask == 0) return i + 1;
```

Sizes are bounded: 64 KiB minimum, 256 KiB average, 1 MiB maximum. The mask is stricter before the average size and looser after it, which keeps chunks near 256 KiB instead of bunching at the minimum.

### Why not fixed-size?
With fixed 256 KiB chunks, inserting one byte near the start of a file shifts every later boundary. Every chunk after the edit gets a new CID, so the DAG diff and the repair path re-transfer the whole file. Content-defined boundaries resynchronise within one or two chunks, so an insertion changes only a couple of blocks and the rest of the DAG is shared.

The trade-off is that a chunker must look at the content to find boundaries, so blocks are no longer aligned to offsets in the file. That is why links in the DAG carry explicit sizes instead of assuming a fixed chunk size.

## 4. Why 64 KiB / 256 KiB / 1 MiB?

The bounds balance three competing needs:
1.  **Deduplication Efficiency**: Smaller chunks increase the chance of finding duplicate data but increase the overhead of managing the Merkle DAG.
2.  **Network Performance**: Larger chunks are more efficient to transfer over high-latency links but make the system less responsive when resuming interrupted downloads.
3.  **Bounded memory**: The chunker holds at most one maximum-size chunk in memory, so the limit doubles as the streaming buffer size.

Because the gear table and seed are part of the on-disk format, changing either changes every CID. Treat them as frozen.

## 5. Memory Efficiency

*   **Slices over Allocations**: The `Block` struct relies on **slices** (`[]const u8`) rather than owning buffers whenever possible.
*   **Streaming**: The chunker reads into one `max_size` buffer (1 MiB), compacts the unconsumed tail to the front, and returns a slice into that buffer. The `DagBuilder` copies each chunk once into a reused tag-prefixed block buffer, hashes it, persists it, and drops it. The whole file is never in memory.
*   **Lifetimes**: A `Block` or `MerkleNode` created during the build process is transient. It exists only long enough to generate its CID and be written to the `StorageEngine`. Only the lightweight CIDs are kept in memory to build the upper layers of the DAG.
*   **Determinism**: Boundaries depend only on file content, not on how the reader delivers bytes, so two nodes chunking the same file produce the same CIDs.

---

**Next Chapters:**
*   [Chapter 3.2: Building the Merkle DAG](./dag.md)
