# Discovery Layer Overview: The "Phonebook"

In a decentralized system without a central server, nodes need a way to find each other's IP addresses and locate where specific data is stored. NomadFS uses a **Distributed Hash Table (DHT)** based on the **Kademlia** algorithm.

## 1. The Core Idea: XOR Metric

Every node in the network is assigned a random 256-bit **NodeID**. Kademlia defines the "distance" between two nodes not by geography or IP hops, but by the **XOR** of their IDs.

$$distance(A, B) = A \oplus B$$

This metric has a special property: it is a **metric space**. It allows nodes to route queries by moving "closer" to the target ID in the ID space, similar to how you find a word in a physical dictionary.

## 2. The Routing Table: k-buckets

To avoid keeping a list of every node in a large network, each node maintains a set of **k-buckets**. 
*   Each bucket corresponds to a specific range of distances from the local node.
*   Nodes that are "close" to us are tracked with high precision.
*   Nodes that are "far" away are tracked with less detail.

This structure ensures that any node can be reached in $O(\log N)$ hops, where $N$ is the total number of nodes in the network.

## 3. Core RPC Operations

The DHT supports four primary operations (RPCs):

1.  **`PING`**: Checks if a node is still online.
2.  **`FIND_NODE`**: Asks a peer for the $k$ nodes it knows that are closest to a target ID.
3.  **`FIND_VALUE`**: Similar to `FIND_NODE`, but if the peer has the requested data (value), it returns it directly.
4.  **`STORE`**: Instructs a peer to store a key-value pair.

## 5. Iterative Lookup: The "Crawler"

The most important part of Kademlia is the iterative lookup process. When a node wants to find a target ID:
1.  It selects the $\alpha$ (usually 3) closest nodes from its own routing table.
2.  It sends `FIND_NODE` requests to them in parallel.
3.  As it receives replies with even closer nodes, it queries those new nodes.
4.  The process continues until no closer nodes can be found or the target is reached.

## 6. Maintenance Strategy

NomadFS has evolved its maintenance strategy from an aggressive "MVP" approach to a more standard, scalable Kademlia implementation.

| Feature | Legacy NomadFS (Aggressive) | Standard Kademlia/NomadFS (Current) |
| :--- | :--- | :--- |
| **Self-Lookup** | Every **10 seconds** (Infinite Loop). | **Once** at startup (to find closest neighbors). |
| **Table Maintenance** | **Ping All** peers every 60s. | **Bucket Refresh**: Lookup a random ID in a bucket only if that bucket has been idle for **1 hour**. |
| **Liveness** | Active Pinging. | **Lazy**: Remove peers only when they fail to respond to a user query. |

This shift ensures the network remains quiet when idle and scales efficiently to thousands of nodes without overwhelming low-power devices.

---

**Next Chapters:**
*   [Chapter 2.1: NodeIDs and XOR Math](./id.md)
*   [Chapter 2.2: K-Bucket Management](./kbucket.md)
*   [Chapter 2.3: Iterative Search](./lookup.md)

