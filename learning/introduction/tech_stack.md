# The Big Picture: The Layers of NomadFS

NomadFS is built as a stack. Each layer uses the one below and knows little
about the ones above. The website's
[How NomadFS works](https://nomadfs.foreachdeveloper.com/learn/) page draws it
as one diagram. This chapter maps each layer to its code.

```
 ┌──────────────────────────────────────────────────────────────┐
 │ App · CLI · FUSE mount        nomadfs-gui/, src/main.zig,    │
 │                               src/fs/fuse.zig                │
 ├──────────────────────────────────────────────────────────────┤
 │ Shared folders · swarm folder src/fs/  (+ src/cluster/)      │
 ├──────────────────────────────────────────────────────────────┤
 │ Blocks & Merkle DAGs          src/storage/                   │
 ├──────────────────────────────────────────────────────────────┤
 │ RPCs & Kademlia DHT           src/net/discovery/             │
 ├──────────────────────────────────────────────────────────────┤
 │ Yamux                         src/net/transport/yamux.zig    │
 │ Noise XXpsk3 + device hello   noise.zig, src/device/auth.zig │
 │ TCP                           tcp.zig, manager.zig           │
 └──────────────────────────────────────────────────────────────┘
```

## Layer 1: Connectivity (the roads)
*   **Problem**: how do two of my devices find each other and talk safely?
*   **Solution**: TCP, then a Noise `XXpsk3` handshake keyed by the swarm key
    and carrying each device's signed Ed25519 identity, then Yamux streams.
    Addresses come from `bootstrap_peers`, invites, LAN announcements
    and the DHT.
*   **Outcome**: one encrypted, authenticated connection per pair of devices,
    carrying many independent streams. See [Chapter 1](../net/transport/overview.md).

## Layer 2: Discovery and RPCs (the phonebook and the post)
*   **Problem**: where is device X, and how do I ask it for something?
*   **Solution**: a Kademlia routing table keyed by node ID, iterative
    `FIND_NODE` lookups, and one request-reply message per Yamux stream (21
    message types, from `PING` to `GET_SWARM` and `ROTATE_KEY`).
*   **Outcome**: any part of NomadFS can reach a device by ID and call it.
    See [Chapter 2](../net/discovery/overview.md).

## Layer 3: Storage (the warehouse)
*   **Problem**: how do I store and move files so that any copy can be
    trusted and edits stay cheap?
*   **Solution**: FastCDC content-defined chunks, SHA-256 content addressing
    over tagged blocks, Merkle DAGs for files and directories, a block
    store that checks every block.
*   **Outcome**: a block from any device can be verified, identical data is
    stored once, and a read loads only the blocks it needs. See
    [Chapter 3](../storage/overview.md).

## Layer 4: Block exchange (the couriers)
*   **Problem**: how do I copy a whole file's DAG from another device?
*   **Solution**: `BlockManager` and `RepairManager` walk a DAG and fetch the
    missing blocks (`GET_BLOCK`). Optionally they announce provider records
    and push replicas to the closest peers.
*   **Outcome**: swarm backup and the library's `put`/`get`. See
    [Chapter 4](../cluster/overview.md).

## Layer 5: Folders (what you see)
*   **Problem**: how do people actually use this?
*   **Solution**: shared folders (scanned into trees, served from the
    original files), the swarm folder (a merged manifest), and a FUSE mount
    on Linux.
*   **Outcome**: `<mount>/<device>/<share>` and `<mount>/Swarm`, and the same
    in the app. See [Chapter 5](../fs/overview.md).

## Alongside: Devices and security
Identity, the trust store, pairing tickets, invites, key rotation and
revocation (`src/device/`) are used by every layer from the handshake up. See
[Chapter 6](../security/model.md).

## One request, end to end

Opening `beach.jpg` from another device's share in the mount:

1. `fuse.zig` receives `READ` from `/dev/fuse` and calls `tree.readAt` with a
   `Remote` loader for that device.
2. `readAt` loads the file's root block. The local store doesn't have it,
   so `Remote.load` calls `BlockManager.connectTo(peer)`. That returns the
   pooled connection, or looks the device up and dials TCP + Noise + Yamux.
3. `dht_node.fetchBlock` opens a Yamux stream and sends `GET_BLOCK <cid>`.
4. The peer's handler reads the block from its store. For a shared file, the
   filestore reads the bytes from the original file and re-hashes them.
5. Back home, `StorageEngine.put` checks SHA-256(bytes) == CID and keeps the
   block. `readAt` follows the parent's link sizes to the leaf holding the
   requested offset, fetches it the same way, and copies the bytes into
   the FUSE reply.
