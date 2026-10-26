# API Reference (Block Operations)

NomadFS exposes a low-level API for block manipulation. High-level file operations are built on top of these primitives.

## 1. Core Data Structures

### `Block`
```zig
pub const Block = struct {
    cid: [32]u8,          // Content Identifier (SHA-256)
    data: []u8,           // Raw byte content
    links: []CID,         // References to child blocks (for DAGs)
};
```

## 2. Operations

### `put(block: Block) -> Result<CID>`
Stores a block in the local system and announces it to the DHT.
- **Input**: Raw data and optional links.
- **Output**: The CID of the stored block.
- **Side Effect**: Updates the Bloom Filter and may trigger replication.

### `get(cid: CID) -> Result<Block>`
Retrieves a block by its Content Identifier.
1.  Checks local storage.
2.  If missing, queries the DHT for providers.
3.  Connects to a provider and requests the block.
4.  Verifies the hash of the received data matches the CID.
- **Error**: Returns `NotFound` if the block cannot be located in the swarm.

### `has(cid: CID) -> bool`
Checks if a block exists locally without retrieving the data.

### `delete(cid: CID) -> Result<void>`
Removes a block from local storage.
**Note**: This does **not** delete the block from the network. Other nodes may still hold copies.

## 3. High-Level Wrappers

### `File.read(path: string)`
Resolves a file path to a root CID, then traverses the Merkle DAG to reassemble the file stream.

### `File.write(path: string, data: Stream)`
Chunks the input stream, creates a Merkle DAG, and updates the root pointer for the given path.
