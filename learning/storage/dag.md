# Chapter 3.2: Building the Merkle DAG

Chunking gives a list of leaves. The **Merkle DAG** links them into one tree with a single root CID, and links files into folders. Diagrams of the same ideas: [Merkle DAG](https://nomadfs.foreachdeveloper.com/learn/merkle-dag/) on the website.

## 1. What is a Merkle DAG?

A **Directed Acyclic Graph** whose nodes are named by the hash of their content. A parent's content includes its children's CIDs, so the root CID commits to every byte below it:

*   **Integrity**: change one byte in one leaf and its CID changes, then its parent's, up to the root.
*   **Deduplication**: identical subtrees have the same CID and are stored once. Two parents may link the same child (hence a DAG, not a tree).
*   **Cheap comparison**: two roots are equal exactly when the two trees are.

## 2. Three Kinds of Block

Every block starts with a tag byte (`codec.Tag`). The format is defined in `src/storage/dag/codec.zig`; all integers are **big-endian**.

```text
leaf:   [0x00][raw chunk bytes ...]

parent: [0x01][u16 link_count]
        link_count × { [cid: 32][u64 size][u16 name_len][name] }

dir:    [0x02][u16 entry_count]
        entry_count × { [cid: 32][u64 size][u8 kind][u64 mtime][u16 name_len][name] }
```

*   **leaf**: one chunk of a file.
*   **parent**: links to children, in order. `size` is the number of file bytes under that child (a leaf's data length, or the sum under a parent). Parents carry no data of their own. Link names are `link-0`, `link-1`, …; readers don't use them.
*   **dir**: one folder. Each entry points at a file DAG (`kind = file`, `size` = file length) or at another dir block (`kind = dir`, `size` = total under it), with an `mtime`.

The CID of any block is `SHA-256` over exactly these bytes (`Block.new`).

### Validation of peer input
Blocks arrive from the network, so `codec.decode(bytes)` fully validates them and returns a `View` (`leaf`, `parent: LinkIterator` or `dir: EntryIterator`) whose slices point into the input:

*   Unknown tags, truncated input and trailing bytes are rejected (`error.InvalidBlock`).
*   Names are checked with `codec.isValidName`: 1–255 bytes, not `.` or `..`, no `/`, `\` or NUL.
*   Dir entries must be in **strictly ascending byte order**, so a folder has exactly one encoding (and one CID), and lookups are a binary search (`tree.Listing.find`).
*   A dir block is at most `max_dir_block_len` = 4 MiB, so a listing always fits one `GET_BLOCK` reply. Parent and dir blocks hold at most 65,535 (`u16`) links.

`encodeParent(allocator, links)` and `encodeDir(allocator, entries)` produce the bytes; `encodeDir` requires sorted, valid, distinct names.

## 3. The Builder's In-Memory Types

`src/storage/dag/node.zig` holds what `DagBuilder` works with before encoding:

```zig
pub const DagLink = struct {
    name: []const u8,
    cid: []const u8,  // 32 bytes
    size: u64,        // bytes under the target
};

pub const MerkleNode = struct {
    links: std.ArrayListUnmanaged(DagLink),
    data: []const u8, // empty for parents
    level: u8,        // 0 = leaf, 1+ = parent
    allocator: Allocator,
};
```

`MerkleNode.totalSize()` is its data length plus the sum of its link sizes. These types never go on the wire; the codec format above does.

## 4. Building a File: `DagBuilder`

`src/storage/dag/builder.zig`:

```zig
pub const DagBuilder = struct {
    allocator: std.mem.Allocator,
    store: *StorageEngine,
    layout: Layout,             // .Balanced everywhere in the node
    leaf_sink: ?LeafSink = null,

    pub fn build(self: *DagBuilder, reader: anytype) ![]const u8; // root CID, caller-owned
};
```

`build` streams the reader through the FastCDC `Chunker` ([Chapter 3.1](./block.md)). For each chunk it writes `0x00 ‖ chunk` into a reused buffer, hashes it, and either stores it or reports it to the `leaf_sink`. It keeps only `(cid, size)` per leaf, then links them:

### Balanced layout (the one in use)
`buildBalanced` groups children into parents of at most **174 links** (`MAX_LINKS`), and repeats layer by layer until one node is left:

```text
                 [parent]                      ← root (≤ 174 links)
        /      |        |      \
   [parent] [parent] [parent] [parent]         ← only for > 174 chunks
   /  |  \     ...
 leaf leaf leaf ...
```

*   A file of **one chunk** has that leaf as its root.
*   An **empty file** is a leaf with no data (`[0x00]`).
*   174 chunks × 256 KiB average ≈ 43 MiB fit under a single parent; anything larger gets another level.

Every caller uses `.Balanced`: `BlockManager` (`layout` field default), the share scanner (`src/fs/scan.zig`) and the swarm folder (`src/fs/swarm.zig`).

### Linear layout (present, unused)
`Layout.Linear` builds a linked list: each spine node links `data` → leaf and `next` → the next spine node. It is exercised only by the builder's tests. There is no Trickle layout.

### The leaf sink (shared folders)
When `leaf_sink` is set, leaves are **not** written to the store. The builder calls `recordFn(ctx, cid, offset, len)` with where the chunk sits in the input, and only parent blocks are stored. The share scanner uses this so shared files are served from the files themselves: see the filestore in [Shared Folders](../fs/shares.md).

## 5. Reading a DAG

*   `walk.readFile(allocator, store, root, writer, options)` writes a whole file from the local store, in link order. `ReadOptions` caps the bytes written, because a small DAG from a peer can reference the same subtree many times.
*   `walk.isComplete` tells whether every block of a DAG is local; `walk.collectReachable` returns every CID under a root (used to push a DAG to a replica and by swarm backup).
*   `tree.readAt` (`src/fs/tree.zig`) reads a byte range by descending from the root and using the link sizes to pick one child per level, so only the blocks covering the range are loaded. That is how shares, the swarm folder and the FUSE mount read files; see [Shared Folders](../fs/shares.md).

## 6. Directories

Folders are **dir blocks**, not parents. `src/fs/scan.zig` turns a local folder into a tree: every regular file becomes a file DAG and every directory a dir block listing its children by name. A share's root CID is its top dir block, and it changes whenever anything under it changes. A device's list of shares is itself a dir block (the `GET_SHARES` reply). See [Shared Folders](../fs/shares.md).

## 7. `DiffService` (not used by the node)

`src/storage/dag/diff.zig` has `DiffService.calculateDiff(old_root, new_root)`: the CIDs reachable from the new root but not the old one, skipping shared subtrees without reading them. It is compiled and tested, but nothing in the node calls it. Fetching a new version is done by the DAG walk in [Chapter 4.1: Repair](../cluster/repair.md), which skips blocks already held and so gets the same effect.

---

**Next Chapters:**
*   [Chapter 3.3: The Disk Engine](./engine.md)
*   [Chapter 4: Block Exchange & Replication](../cluster/overview.md)
