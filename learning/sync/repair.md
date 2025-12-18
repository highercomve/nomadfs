# Chapter 4.2: Merkle Tree Repair (Anti-Entropy)

Nodes in NomadFS can go offline at any time. When they reconnect, they need an efficient way to find out what they missed without downloading everything again. This process is called **Anti-Entropy** or **Background Repair**.

## 1. The Challenge

Imagine a node has 1,000,000 blocks. It reconnects after two days. Another node also has 1,000,000 blocks. They need to find the 50 blocks that are different between them.

A naive approach would be to list all CIDs, but that would use too much bandwidth.

## 2. Merkle Tree Comparison

NomadFS uses Merkle Trees (distinct from the file DAGs) to represent the *set* of all CIDs stored on a node.

1.  Each node builds a Merkle Tree where the leaves are the CIDs of all the blocks it owns.
2.  Nodes exchange the **Root Hash** of their respective Merkle Trees.
3.  If the root hashes match, the nodes are perfectly in sync.
4.  If they don't match, they exchange the hashes of the next level down (the children).
5.  By recursing down the tree, they can quickly narrow down the exact sub-trees that differ.

This allows identifying missing blocks in $O(\log N)$ time, where $N$ is the number of blocks.

## 3. The Sync Protocol (WANT List)

Once a node knows which CIDs it is missing, it initiates a transfer using a "WANT List."

1.  **Request**: "I want CID `QmXyZ...`"
2.  **Response**: The peer sends the `DagNode` or `Block` corresponding to that CID.
3.  **Recursion**: If the received item is a `DagNode`, the node checks its links. If any of those links are also missing, it adds them to the WANT list.

```zig
pub fn sync(peer: network.Connection, root_cid: []const u8) !void {
    // 1. Send WANT list (root_cid)
    // 2. Peer sends DAG node
    // 3. Decode DAG node, find missing children
    // 4. Recursively fetch missing children
}
```

## 4. Periodic vs. Reactive Repair

NomadFS performs repair in two ways:
*   **Reactive**: When a node joins the swarm, it immediately checks sync with its neighbors on the hash ring.
*   **Periodic**: Every hour, nodes pick a random neighbor and perform a Merkle tree comparison to ensure no data has been lost due to bit rot or silent failures.

---

**Next Chapters:**
*   [Chapter 4.3: Quorum Logic & Availability](./quorum.md)
