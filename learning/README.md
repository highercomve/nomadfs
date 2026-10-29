# The NomadFS Internals Book

This book explains how NomadFS is built, at the level of the code: which file
does what, which types and functions carry each idea, and why. It is for
developers who want to read, change or review the source.

For a shorter, diagram-led tour of the main technologies (TCP, Noise, Yamux,
SHA-256, FastCDC, Merkle DAGs, the swarm folder CRDT and FUSE), read the
**Learn** section of the website first:
<https://nomadfs.foreachdeveloper.com/learn/>. The chapters here link to the
matching Learn page and then go deeper. How to *use* NomadFS is covered by the
user docs: <https://nomadfs.foreachdeveloper.com/docs/>.

## 1. What is NomadFS?

NomadFS is a personal filesystem for the devices you own: a laptop, a phone, a
home server. These devices change networks, sleep and go offline. Each device
keeps its own files. What you share is listed on every device, and a file's
bytes travel only when someone opens it.

- **Shared folders.** A folder on one device, published under a name. The
  other devices browse it and fetch file contents on demand. Shares are
  read-only for the other devices.
- **The swarm folder.** One folder that belongs to the whole swarm. Any
  device can add, rename and delete files in it. Edits merge without a
  server, and concurrent edits keep both versions.
- **A Linux mount.** Everything above as an ordinary folder, through FUSE.
- **An app.** A GUI for the Linux desktop and Android, built with
  [Oriel](https://oriel.foreachdeveloper.com).

There is no central server. Devices that hold the same **swarm key** form a
private swarm. Every connection is encrypted and authenticated with Noise, and
every device has an Ed25519 identity that can be paired, trusted and revoked.

What NomadFS does **not** do: it does not encrypt data at rest. Blocks, shared
files and the swarm manifest are plain files on each device. Only the
transport between devices is encrypted. See
[Chapter 6.1: Security Model](./security/model.md).

## 2. The Technology Stack

NomadFS is written in **Zig 0.16** (`minimum_zig_version = "0.16.0"` in
`build.zig.zon`) and uses only the Zig standard library: no libc, no libfuse,
no TLS or crypto libraries. The app adds Oriel.

| Part | Code | Purpose |
| :--- | :--- | :--- |
| **Transport** | `src/net/transport/` | TCP, the Noise `XXpsk3` handshake, Yamux streams, LAN announcements, UPnP. |
| **Discovery** | `src/net/discovery/` | The Kademlia DHT and every RPC (`GET_BLOCK`, `GET_SHARES`, `GET_SWARM`, …). |
| **Storage** | `src/storage/` | FastCDC chunking, SHA-256 content addressing, Merkle DAG blocks, the block store. |
| **Cluster** | `src/cluster/` | Moving whole DAGs between devices: provider records, replication, fetch. |
| **Folders** | `src/fs/` | Shared folders and the filestore, the swarm folder CRDT, the FUSE mount. |
| **Devices** | `src/device/` | Ed25519 identity, the trust store, pairing tickets, invites, key rotation. |
| **Node** | `src/root.zig`, `src/main.zig` | Wires everything together; the command line. |
| **Mobile** | `src/mobile/` | A C ABI (`libnomadfs`) and Swift bindings. |
| **App** | `nomadfs-gui/` | The desktop and Android app, built with Oriel. |

[The Tech Stack](./introduction/tech_stack.md) shows how the layers fit.

## 3. Recommended Reading

* **Distributed hash tables**: [Kademlia: A Peer-to-peer Information System Based on the XOR Metric](https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf).
* **Cryptography and networking**: [The Noise Protocol Framework](https://noiseprotocol.org/noise.html) (NomadFS uses `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`) and the [Yamux specification](https://github.com/hashicorp/yamux/blob/master/spec.md).
* **Chunking**: [FastCDC: a Fast and Efficient Content-Defined Chunking Approach for Data Deduplication](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia) (USENIX ATC 2016).
* **Data structures**: [Merkle DAGs](https://docs.ipfs.tech/concepts/merkle-dag/), and Shapiro et al., [Conflict-free Replicated Data Types](https://hal.inria.fr/inria-00609399) (2011), for the swarm folder.
* **FUSE**: the kernel's [FUSE documentation](https://www.kernel.org/doc/html/latest/filesystems/fuse.html) and `include/uapi/linux/fuse.h`.

## Table of Contents

### Part I: Introduction & Architecture
1.  **[Vision & Philosophy](./introduction/vision.md)**: roaming devices, what NomadFS keeps local and what it shares.
2.  **[Architecture](./introduction/architecture.md)**: the `Node`, how it starts, the CLI, the app and the mobile library.
3.  **[The Tech Stack](./introduction/tech_stack.md)**: the layers and how a request moves through them.

### Part II: The Connectivity Stack (`src/net/`)
4.  **[Chapter 1: Transport Layer](./net/transport/overview.md)**
    *   [1.1: Security & the Noise Handshake](./net/transport/noise.md)
    *   [1.2: Multiplexing with Yamux](./net/transport/yamux.md)
    *   [1.3: Testing Network Logic](./net/transport/testing.md)
    *   [1.4: Connection Management](./net/transport/management.md)
    *   [1.5: Local Discovery (LAN Announcements)](./net/transport/mdns.md)
    *   [1.6: UPnP & DIAL_BACK](./net/transport/nat.md)
    *   [1.7: Relaying Through Another Device](./net/transport/relay.md)
5.  **[Chapter 2: Discovery Layer (DHT)](./net/discovery/overview.md)**
    *   [2.1: NodeIDs and XOR Math](./net/discovery/id.md)
    *   [2.2: K-Bucket Management](./net/discovery/kbucket.md)
    *   [2.3: Iterative Search](./net/discovery/lookup.md)
    *   [2.4: RPC Messages and Serialization](./net/discovery/rpc.md)

### Part III: The Storage Stack (`src/storage/`)
6.  **[Chapter 3: Content Addressing](./storage/overview.md)**
    *   [3.1: Chunking & Blocks](./storage/block.md)
    *   [3.2: Building the Merkle DAG](./storage/dag.md)
    *   [3.3: The Disk Engine](./storage/engine.md)

### Part IV: Block Exchange (`src/cluster/`)
7.  **[Chapter 4: Block Exchange & Replication](./cluster/overview.md)**
    *   [4.1: Fetching DAGs (Repair)](./cluster/repair.md)
    *   [4.2: The Write Quorum](./cluster/quorum.md)
    *   [4.3: The Hash Ring (present, unused)](./cluster/ring.md)
    *   [4.4: Vector Clocks (present, unused) and what the swarm folder uses](./cluster/vectors.md)

### Part V: Folders (`src/fs/`)
8.  **[Chapter 5: Folders](./fs/overview.md)**
    *   [5.1: Shared Folders and the Filestore](./fs/shares.md)
    *   [5.2: The Swarm Folder](./fs/swarm.md)
    *   [5.3: Folder Backup](./fs/backup.md)
    *   [5.3: The FUSE Mount](./fs/fuse.md)

### Part VI: Devices & Security (`src/device/`)
9.  **[Chapter 6: Security](./security/model.md)**
    *   [6.1: Security Model & Threat Analysis](./security/model.md)
    *   [6.2: Device Identity & Pairing](./security/pairing.md)
    *   [6.3: Invites, Key Rotation & Revocation](./security/invites.md)

### Part VII: Applications
10. **[Chapter 7: The App (`nomadfs-gui/`)](./app/gui.md)**

### Part VIII: Operations & Reference
11. **[Chapter 8: Operations](./ops/deployment.md)**
    *   [8.1: Installation & Running](./ops/deployment.md)
    *   [8.2: Configuration Reference](./ops/configuration.md)
    *   [8.3: Observability](./ops/observability.md)
    *   [8.4: Performance Notes & Limits](./ops/performance.md)
12. **[Chapter 9: API Reference (Zig)](./api/reference.md)**
13. **[Chapter 10: The Mobile C ABI & Bindings](./mobile/api.md)**
14. **[Chapter 11: Testing](./testing.md)**

## 4. Where NomadFS Is Going

[ROADMAP.md](../ROADMAP.md) describes a shift from a general distributed
block store (hash rings, quorums) to a personal device mesh: directed sync
and backup policies, a headless always-on node that can relay between
devices behind strict NATs, and more capabilities (clipboard, camera,
notifications) over the same encrypted connection. Chapters mark such plans
as **Not implemented yet**. Anything described without that label exists in
the code today.

## 5. Getting Started with the Code

If you are reading the source alongside this book, start here:
*   `src/root.zig`: the `Node`, which creates and connects every part.
*   `src/main.zig`: the command line (`--share`, `--invite`, `--mount`, …).
*   `src/config.zig`: the `nomadfs.conf` parser. The file is read from the
    current folder, `~/.nomadfs/` or `/etc/nomadfs/`.
*   `nomadfs-gui/src/commands.zig`: what the app asks the core to do.

Build with `zig build` and run the tests with `zig build test` (see
[Chapter 11: Testing](./testing.md)).
