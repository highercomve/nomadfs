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
*   **Deduplication**: If two different files contain the same 256KB chunk of data, that chunk is only stored once in the system, as they both share the same CID.

## 3. Chunking Strategies

A large file must be split into multiple blocks. The component responsible for this is the `Chunker`.

### Fixed-Size Chunking
Currently, NomadFS implements a simple fixed-size chunking strategy. The file is sliced into 256 KB segments (the default size).

```zig
pub fn chunk(data: []const u8, chunk_size: usize, allocator: std.mem.Allocator) ![]Block {
    var blocks = std.ArrayList(Block).init(allocator);
    var i: usize = 0;
    while (i < data.len) {
        const end = @min(i + chunk_size, data.len);
        const slice = data[i..end];
        try blocks.append(Block.new(slice));
        i = end;
    }
    return blocks.toOwnedSlice();
}
```

### Content-Defined Chunking (Future)
In the future, NomadFS plans to implement **Content-Defined Chunking (CDC)** using algorithms like Rabin Fingerprinting. CDC allows for better deduplication when bytes are inserted or deleted in the middle of a file, as the chunk boundaries "shift" with the content.

## 4. Why 256 KB?

We chose 256 KB as the default chunk size to balance two competing needs:
1.  **Deduplication Efficiency**: Smaller chunks increase the chance of finding duplicate data but increase the overhead of managing the Merkle DAG.
2.  **Network Performance**: Larger chunks are more efficient to transfer over high-latency links but make the system less responsive when resuming interrupted downloads.

## 5. Memory Efficiency (The Zero-Copy Rule)

A core mandate of NomadFS is to avoid unnecessary memory copying.

*   **Slices over Allocations**: The `Block` struct and `Chunker` logic rely on **slices** (`[]const u8`) rather than owning buffers whenever possible.
*   **Streaming**: When processing large files, we read data into a fixed-size buffer (e.g., 256 KB), hash it, persist it, and discard it *immediately*. We do **not** load the entire file into memory.
*   **Lifetimes**: A `Block` or `MerkleNode` created during the build process is transient. It exists only long enough to generate its CID and be written to the `StorageEngine`. Only the lightweight CIDs are kept in memory to build the upper layers of the DAG.

---

**Next Chapters:**
*   [Chapter 3.2: Building the Merkle DAG](./dag.md)
