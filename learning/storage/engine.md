# Chapter 3.3: The Disk Engine

The `StorageEngine` is the component that actually talks to the hardware. It is responsible for persisting and retrieving blocks from the local disk.

## 1. Flat-File CID Storage

On a storage node, blocks are stored in a dedicated directory (configured in `roaming.conf` as `storage_path`). 

Each block is stored as a file where the **filename is the hex-encoded CID**.

```text
nomad_data/
├── 0a2f1b...
├── 3e4d9c...
└── f7a201...
```

This simple structure allows for:
*   **Fast Lookups**: Finding a block is a single `open()` call if you know the CID.
*   **Implicit Deduplication**: Trying to write a block that already exists just overwrites (or skips) the same file.

## 2. Implementation

The engine uses Zig's `std.fs.Dir` for directory operations.

```zig
pub fn put(self: *StorageEngine, block: Block) !void {
    const hex_cid = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&block.cid)});
    defer self.allocator.free(hex_cid);

    const file = try self.root_dir.createFile(hex_cid, .{});
    defer file.close();

    try file.writeAll(block.data);
}
```

## 3. Client-Only Nodes

On mobile devices or other client-only nodes, the `StorageEngine` may be disabled or limited to a small temporary cache. This ensures that roaming devices don't consume excessive storage by acting as a repository for other peers' data.

## 4. Future Enhancements

*   **Subdirectories**: To avoid performance issues with thousands of files in a single directory, we plan to shard files into subdirectories (e.g., `ab/cdef...`).
*   **Garbage Collection**: Identifying and deleting blocks that are no longer part of any file's Merkle DAG.
*   **Encryption at Rest**: Encrypting the blocks on disk so that even a stolen device doesn't leak data without the swarm key.

---

**Next Chapters:**
*   [Chapter 4: The Sync Layer](../sync/overview.md)
