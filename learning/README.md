# The NomadFS Internals Book

Welcome to the **NomadFS Internals Book**. This directory contains detailed documentation about the architecture, algorithms, and implementation details of NomadFS. It is written for developers, students, and curious minds who want to understand how a modern Distributed File System (DFS) is built from scratch.

## 1. What is NomadFS?

NomadFS is a **private, decentralized, distributed file system** designed specifically for "Roaming Devices"—laptops, phones, and home servers that frequently change IP addresses or go offline.

Unlike cloud storage (Dropbox, Google Drive), NomadFS has no central server. Your data lives on your devices. Unlike public P2P networks (IPFS, BitTorrent), NomadFS is private and encrypted by default; only devices with your "Swarm Key" can join.

### Core Philosophy
*   **Local-First**: You can read and write files even when offline. Changes sync when you reconnect.
*   **Partition Tolerant**: The system handles network splits gracefully.
*   **Private**: All data is encrypted in transit and at rest.

## 2. The Technology Stack

NomadFS is built using **Zig 0.15.2**. We chose Zig for its performance, safety, and lack of hidden control flow (no exceptions, no hidden memory allocations).

The system is composed of four major layers:

| Layer | Component | Purpose | Technology/Algorithm |
| :--- | :--- | :--- | :--- |
| **1. Network** | [The Roads](./network/overview.md) | Secure, multiplexed p2p connections. | TCP, **Noise Protocol**, Yamux |
| **2. Discovery & Storage** | The Phonebook & Warehouse | Finding peers and storing raw blocks. | **Kademlia DHT**, **StorageEngine** |
| **3. Block Exchange** | The Brain | Orchestrating DHT, Network, and Storage. | **BlockManager** (Coordinator) |
| **4. Application/API** | The User Interface | Unified API for put/get operations. | **Node** (Orchestrator) |

## 3. Recommended Reading

To fully understand NomadFS, familiarity with these concepts is helpful. We have curated a list of the best resources:

*   **Distributed Hash Tables (DHTs)**:
    *   [Kademlia: A Peer-to-peer Information System Based on the XOR Metric](https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf) (Original Paper)
    *   [The IPFS DHT Specification](https://github.com/libp2p/specs/tree/master/kad-dht)
*   **Cryptography & Networking**:
    *   [The Noise Protocol Framework](http://noiseprotocol.org/noise.html) (We use `XXpsk3`)
    *   [Yamux Specification](https://github.com/hashicorp/yamux/blob/master/spec.md)
*   **Data Structures**:
    *   [Merkle Directed Acyclic Graphs (DAGs)](https://docs.ipfs.tech/concepts/merkle-dag/)
    *   [Consistent Hashing](https://en.wikipedia.org/wiki/Consistent_hashing)

## Table of Contents

### Part I: Introduction & Architecture
1.  **[Vision & Philosophy](./introduction/vision.md)**
    *   The problem of Roaming Devices.
    *   Availability and Partition Tolerance (AP).
2.  **[Deployment Modes](./introduction/architecture.md)**
    *   Storage Nodes vs. Client-Only Nodes.
    *   Mobile integration (JNI/Swift).
3.  **[The Tech Stack](./introduction/tech_stack.md)**
    *   Overview of the 4 layers.

### Part II: The Network Layer
4.  **[Chapter 1: Overview](./network/overview.md)**
    *   [1.1: Security & Noise](./network/noise.md)
    *   [1.2: Multiplexing with Yamux](./network/yamux.md)
    *   [1.3: Testing Strategy](./network/testing.md)
    *   [1.4: Connection Management](./network/management.md)

### Part III: Peer Discovery (DHT)
5.  **[Chapter 2: Kademlia & The XOR Metric](./dht/overview.md)**
    *   [2.1: NodeIDs and XOR Math](./dht/id.md)
    *   [2.2: K-Bucket Management](./dht/kbucket.md)
    *   [2.3: Iterative Search](./dht/lookup.md)
    *   [2.4: DHT RPC and Serialization](./dht/rpc.md)

### Part IV: Storage & Sync
6.  **[Chapter 3: Merkle DAGs & Content Addressing](./storage/overview.md)**
    *   [3.1: Chunking & Blocks](./storage/block.md)
    *   [3.2: Building DAGs](./storage/dag.md)
    *   [3.3: The Disk Engine](./storage/engine.md)
7.  **[Chapter 4: Vector Clocks & Consistency](./sync/overview.md)**
    *   [4.1: Conflict Resolution](./sync/vectors.md)
    *   [4.2: Anti-Entropy Repair](./sync/repair.md)
    *   [4.3: Quorum Logic](./sync/quorum.md)
8.  **[Chapter 5: Distribution](./dist/ring.md)**
    *   [5.1: Consistent Hashing & The Ring](./dist/ring.md)

## 5. Getting Started with the Code

If you are reading the source code alongside this documentation, start here:
*   `src/root.zig`: The core library and **Node Orchestrator**. This is where all layers are unified.
*   `src/main.zig`: The entry point for the desktop CLI, which uses the `Node` struct.
*   `nomadfs.conf`: The configuration file that controls the node's behavior.

Enjoy the dive!
