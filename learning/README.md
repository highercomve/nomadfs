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

The system is composed of three major layered stacks:

| Stack | Layers | Purpose |
| :--- | :--- | :--- |
| **1. Connectivity (`net/`)** | [Transport](./net/transport/overview.md) & [Discovery](./net/discovery/overview.md) | Secure pipes and finding peers. |
| **2. Storage (`storage/`)** | [Blocks](./storage/block.md) & [DAGs](./storage/dag.md) | Local content-addressed persistence. |
| **3. Distribution (`dist/`)** | [Ring](./dist/ring.md), [Quorum](./dist/quorum.md), [Sync](./dist/overview.md) | Swarm coordination and consistency. |

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
    *   Overview of the 3 layered stacks.

### Part II: The Connectivity Stack (`src/net/`)
4.  **[Chapter 1: Transport Layer](./net/transport/overview.md)**
    *   [1.1: Security & Noise](./net/transport/noise.md)
    *   [1.2: Multiplexing with Yamux](./net/transport/yamux.md)
    *   [1.3: Testing Strategy](./net/transport/testing.md)
    *   [1.4: Connection Management](./net/transport/management.md)
    *   [1.5: Local Discovery (mDNS)](./net/transport/mdns.md)
    *   [1.6: NAT & AutoNAT](./net/transport/nat.md)
5.  **[Chapter 2: Discovery Layer (DHT)](./net/discovery/overview.md)**
    *   [2.1: NodeIDs and XOR Math](./net/discovery/id.md)
    *   [2.2: K-Bucket Management](./net/discovery/kbucket.md)
    *   [2.3: Iterative Search](./net/discovery/lookup.md)
    *   [2.4: DHT RPC and Serialization](./net/discovery/rpc.md)

### Part III: The Storage Stack (`src/storage/`)
6.  **[Chapter 3: Content Addressing](./storage/overview.md)**
    *   [3.1: Chunking & Blocks](./storage/block.md)
    *   [3.2: Building DAGs](./storage/dag.md)
    *   [3.3: The Disk Engine](./storage/engine.md)

### Part IV: The Distribution Stack (`src/dist/`)
7.  **[Chapter 4: Consistency & Sync](./dist/overview.md)**
    *   [4.1: Vector Clocks](./dist/vectors.md)
    *   [4.2: Merkle Tree Repair](./dist/repair.md)
    *   [4.3: Quorum Logic](./dist/quorum.md)
8.  **[Chapter 5: Distribution](./dist/ring.md)**
    *   [5.1: Consistent Hashing & The Ring](./dist/ring.md)

## 5. Getting Started with the Code

If you are reading the source code alongside this documentation, start here:
*   `src/root.zig`: The core library and **Node Orchestrator**. This is where all stacks are unified.
*   `src/main.zig`: The entry point for the desktop CLI.
*   `nomadfs.conf`: The configuration file.

Enjoy the dive!