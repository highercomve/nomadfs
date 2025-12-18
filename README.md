# NomadFS

NomadFS is a private, decentralized distributed file system (DFS) optimized for **Roaming Devices**—laptops, phones, and home servers that frequently change IP addresses or go offline.

Unlike traditional distributed systems that prioritize consistency (CP), NomadFS prioritizes **Availability** and **Partition Tolerance** (AP in the CAP theorem). It allows for local writes while offline and synchronizes changes automatically upon reconnection using advanced conflict resolution strategies.

## 🚀 Core Philosophy

- **Offline First:** Local writes are always successful ($W=1$), ensuring you can work regardless of connectivity.
- **Privacy by Design:** Peer communication is encrypted and authenticated using the Noise Protocol Framework.
- **Decentralized Discovery:** No central "introducer." Nodes find each other via a Kademlia-based Distributed Hash Table (DHT).
- **TigerStyle Engineering:** Built with Zig 0.15.2, following rigorous safety and performance principles (static allocation, explicit control flow).

## 🛠 Tech Stack

- **Language:** [Zig 0.15.2](https://ziglang.org/)
- **Transport:** TCP (with abstraction for future QUIC support)
- **Security:** Noise Protocol Framework (**`XXpsk3`** pattern) for mutual authentication and private swarms.
- **Multiplexing:** **Yamux** for multiple logical streams over a single connection.
- **Discovery:** **Kademlia DHT** (XOR metric, k-buckets).
- **Storage:** **Merkle DAG** for content addressing (CIDs) and deduplication.
- **Consistency:** **Consistent Hashing** with Virtual Nodes for data placement and **Vector Clocks** for causal history tracking.

## 🏗 Architecture

NomadFS operates in two modes:

1.  **Storage Node (Full Peer):** Participates in the DHT, stores data blocks for the swarm, and joins the Consistent Hash Ring.
2.  **Client-Only Node (Roaming):** Acts as a gateway (e.g., mobile devices). It encrypts/decrypts data locally but does not store blocks for other peers to save battery and storage.

## ⚙️ Configuration

The system is configured via `roaming.conf`. Example:

```ini
[node]
nickname = "MyLaptop"
swarm_key = "your-private-swarm-key" 

[storage]
enabled = true 
storage_path = "./nomad_data"

[network]
port = 9000
bootstrap_peers = ["tcp://192.168.1.5:9000"]
```

## 🛠 Getting Started

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/)

### Build & Run

```bash
# Build the executable
zig build

# Run the node
zig build run -- --config nomadfs.conf

# Run all tests (Unit + Integration)
zig build test
```

### 🐳 Docker

You can run NomadFS as a container. The image is designed to be minimal and secure.

#### Build the image

```bash
# Build for current platform
docker build -t highercomve/nomadfs:latest .

# Build for multiple platforms using buildx
docker buildx build --platform linux/amd64,linux/arm64 -t highercomve/nomadfs:latest .
```

#### Run the container

To run a storage node, you should mount a configuration file and a directory for persistent data:

```bash
docker run -d \
  --name nomadfs \
  -p 9000:9000 \
  -v $(pwd)/nomadfs.conf:/etc/nomadfs/nomadfs.conf \
  -v $(pwd)/nomad_data:/var/lib/nomadfs \
  highercomve/nomadfs:latest
```

## 📖 Documentation

For a deep dive into the internals, algorithms, and design decisions, check out the [NomadFS Internals Book](./learning/README.md):

- [Architecture & Vision](./learning/introduction/vision.md)
- [Networking & Noise Handshake](./learning/network/noise.md)
- [Kademlia DHT Implementation](./learning/dht/overview.md)
- [Storage Engine & Merkle DAG](./learning/storage/overview.md)
- [Conflict Resolution & Sync](./learning/sync/overview.md)
