# Chapter 3.2: Building the Merkle DAG

Once a file is split into blocks, we need a way to link them together to represent the original file. NomadFS uses a **Merkle Directed Acyclic Graph (DAG)** for this purpose.

## 1. What is a Merkle DAG?

A Merkle DAG is a graph where:
*   Nodes are addressed by their cryptographic hash (CID).
*   Nodes can contain data and links (pointers) to other nodes.
*   Because it's a DAG, there are no cycles.

In NomadFS, a file is a tree where the root node represents the entire file, and its children are the individual chunks (or intermediate nodes).

## 2. The `DagNode` Structure

A `DagNode` in NomadFS is defined as:

```zig
pub const Link = struct {
    name: []const u8, // e.g., "part_1"
    cid: [32]u8,      // Child CID
    size: u64,        // Size of the child node
};

pub const DagNode = struct {
    data: []const u8,
    links: []Link,
};
```

*   **`data`**: Can contain raw bytes (for leaf nodes) or metadata (for internal nodes).
*   **`links`**: An array of `Link` objects pointing to other `DagNodes` or `Blocks`.

## 3. Serialization

To store or transmit a `DagNode`, it must be encoded into a binary format. NomadFS uses a simple, efficient custom binary encoding (though we may move to IPLD/CBOR in the future).

The current format is:
1.  `num_links` (u32, little-endian)
2.  For each link:
    *   `name_len` (u32)
    *   `name` (bytes)
    *   `cid` (32 bytes)
    *   `size` (u64)
3.  `data_len` (u32)
4.  `data` (bytes)

## 4. Verification

One of the most powerful properties of a Merkle DAG is **Partial Verification**. 

If you download the root node of a 10 GB file, you immediately know the CIDs of all its children. When you download a child chunk, you can hash it and compare it to the CID stored in the parent. If it matches, you *know* that chunk is authentic, even if you don't have the rest of the file yet.

## 5. Directory Structures

Directories are also `DagNodes`. Instead of raw file data, the `links` in a directory node point to the CIDs of the files and subdirectories it contains.

---

**Next Chapters:**
*   [Chapter 4: The Sync Layer](../sync/overview.md)
