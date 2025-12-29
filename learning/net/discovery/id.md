# Chapter 2.1: NodeIDs and XOR Math

In NomadFS, every participant is identified by a **NodeID**. This ID is the foundation of how we find peers and data in a decentralized network.

## 1. What is a NodeID?

A NodeID is a 256-bit (32-byte) unique identifier.
*   It is typically generated randomly when a node is first initialized.
*   In the future, we may derive it from the static public key used in the Noise handshake.

## 2. The XOR Metric

Traditional distance (Euclidean) doesn't work well for routing in a massive, flat ID space. Kademlia uses the **Exclusive OR (XOR)** operation to define distance.

For any two IDs, $A$ and $B$, the distance is:
$$d(A, B) = A \oplus B$$

### Why XOR?
XOR is a **metric** because it satisfies:
1.  **Identity**: $d(A, A) = 0$.
2.  **Symmetry**: $d(A, B) = d(B, A)$.
3.  **Triangle Inequality**: $d(A, B) + d(B, C) \ge d(A, C)$.

### Bitwise Interpretation
XOR distance behaves like a hierarchical tree. If two IDs share a long prefix of identical bits, their XOR distance will be small. If they differ at the very first bit, their distance is enormous (at least $2^{255}$).

In NomadFS, we calculate the **Common Prefix Length (CPL)**, which is the number of leading zero bits in the XOR distance.

```zig
pub fn commonPrefixLen(self: NodeID, other: NodeID) u8 {
    const dist = self.distance(other);
    var zeros: u8 = 0;
    for (dist.bytes) |byte| {
        if (byte == 0) {
            zeros += 8;
        } else {
            // @clz counts leading zeros in a byte (0..8)
            zeros += @intCast(@clz(byte));
            break;
        }
    }
    return zeros;
}
```

## 3. Comparing Distances

When searching for a target ID, we often need to know which of two peers is "closer" to that target. We compare the XOR distances lexicographically (from the most significant byte to the least).

```zig
pub fn compareDistance(target: NodeID, a: NodeID, b: NodeID) std.math.Order {
    const dist_a = xorDistance(target, a);
    const dist_b = xorDistance(target, b);
    
    for (0..32) |i| {
        if (dist_a[i] < dist_b[i]) return .lt;
        if (dist_a[i] > dist_b[i]) return .gt;
    }
    return .eq;
}
```

This simple math allows every node to navigate a massive global network using only local knowledge.
