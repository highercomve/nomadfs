# Synchronization Overview: The "Brain"

Distribution is easy when you are online, but NomadFS is built for "Roaming Devices." The synchronization layer manages how data is replicated across the swarm and how we resolve conflicts when two devices edit the same file while offline.

## 1. Replication Strategy

NomadFS uses **Consistent Hashing** to decide which nodes store which data.
*   Nodes and Data Blocks are mapped onto a 256-bit circular "Ring."
*   A block is stored on the $N$ nodes (default $N=3$) that appear clockwise from the block's CID on the ring.
*   See [Chapter 5.1: Consistent Hashing & The Ring](../dist/ring.md) for details.

## 2. Eventual Consistency ($W=1$)

To support offline writes, NomadFS uses a **Write Quorum of 1**. 
*   When you save a file on your laptop, it is saved locally immediately. 
*   If you have internet, the laptop tries to push it to the other 2 nodes in the replica set.
*   If you are offline, the write is still successful. The system "remembers" to sync later.

## 3. Conflict Detection: Vector Clocks

When two devices edit the same file while disconnected (e.g., you edit a doc on your laptop and your phone simultaneously), we need a way to detect that a conflict occurred.

NomadFS uses **Vector Clocks**. Each file has a version metadata that looks like this:
`[(Laptop, 5), (Phone, 2)]`

*   If Device A's clock is "greater" than Device B's, Device A has the latest version.
*   If neither is greater, we have a **Conflict**.

## 4. Anti-Entropy & Repair

Even if no conflicts occur, nodes might miss data due to downtime. NomadFS periodically performs **Anti-Entropy** (background repair):
*   Nodes compare their Merkle Trees of stored CIDs.
*   They identify exactly which blocks are missing from which node.
*   They transfer only the missing blocks to bring everyone back into sync.

---

**Next Chapters:**
*   [Chapter 4.1: Vector Clocks in Practice](./vectors.md)
*   [Chapter 4.2: Merkle Tree Repair](./repair.md)
*   [Chapter 4.3: Quorum Logic](./quorum.md)
