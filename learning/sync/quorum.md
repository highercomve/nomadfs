# Chapter 4.3: Quorum Logic & Availability

NomadFS is an **AP** system (Availability and Partition Tolerance) according to the CAP theorem. We achieve this by allowing users to tune the consistency of reads and writes through **Quorum Logic**.

## 1. The N, R, W Model

NomadFS uses the same replication model as Amazon Dynamo:
*   **$N$ (Replication Factor)**: The total number of nodes that should store a copy of a data block. Default is 3.
*   **$W$ (Write Quorum)**: The number of nodes that must acknowledge a write for it to be considered "successful." Default is 1.
*   **$R$ (Read Quorum)**: The number of nodes that must respond to a read request to return a result. Default is 1.

## 2. Why $W=1$ for NomadFS?

The primary goal of NomadFS is to support **Roaming Devices** that are often offline. 
*   If we required $W=2$ or $W=3$, a user would be unable to save a file on their laptop unless they were connected to the internet and could reach other nodes.
*   With $W=1$, the write is successful as long as it is stored on the local node. The distribution to other $N-1$ nodes happens asynchronously in the background.

## 3. Strong vs. Eventual Consistency

*   **Strong Consistency**: Achieved when $R + W > N$. For example, if $N=3$, $R=2$, and $W=2$, any read is guaranteed to see the latest write.
*   **Eventual Consistency**: When $R + W \le N$. NomadFS defaults to this to maximize availability. If you write to your laptop while offline and then read from your phone, you won't see the change until the devices have had a chance to synchronize.

## 4. Implementation

The quorum logic is implemented in `src/dist/quorum.zig`:

```zig
pub const QuorumConfig = struct {
    N: u8 = 3,
    W: u8 = 1,
    R: u8 = 1,
};

pub fn isWriteSatisfied(config: QuorumConfig, successful_writes: u8) bool {
    return successful_writes >= config.W;
}
```

## 5. Availability during Partitions

Because $W=1$, NomadFS can survive any number of node failures and network partitions. You can always write to your local partition. The trade-off is that you must handle **Conflicts** (via [Vector Clocks](./vectors.md)) when partitions merge.

---

**Next Chapters:**
*   [Conclusion and Next Steps](../README.md)
