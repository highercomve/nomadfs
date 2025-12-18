# Chapter 4.1: Vector Clocks in Practice

To handle offline writes and eventual consistency, NomadFS needs a way to track the history of changes to a file and detect when two devices have made conflicting edits. We use **Vector Clocks** for this.

## 1. Why Not Timestamps?

System clocks (wall-clock time) are notoriously unreliable in distributed systems. They drift, they can be set incorrectly by users, and they don't provide a guaranteed "happened-before" relationship.

Vector clocks provide **Logical Time**, which tracks causality based on actual events rather than seconds.

## 2. The Vector Clock Structure

A Vector Clock is essentially a map of `NodeID -> Counter`.

```zig
pub const VectorClock = struct {
    pub const Entry = struct {
        node_id: []const u8,
        counter: u64,
    };
    entries: std.ArrayList(Entry),
};
```

*   When a node performs a write, it increments its own counter in the vector.
*   When nodes sync, they merge their vector clocks by taking the maximum counter for each node ID.

## 3. Comparison Logic

Comparing two vector clocks ($V_1$ and $V_2$) results in one of four states:

1.  **Equal**: $V_1 = V_2$ for all entries. (No changes)
2.  **Less (Ancestor)**: $V_1 \le V_2$ for all entries, and $V_1 < V_2$ for at least one. ($V_1$ happened before $V_2$)
3.  **Greater (Descendant)**: $V_1 \ge V_2$ for all entries, and $V_1 > V_2$ for at least one. ($V_2$ happened before $V_1$)
4.  **Concurrent (Conflict)**: Neither $V_1 \le V_2$ nor $V_2 \le V_1$ is true. (Both nodes edited the file without knowing about each other's changes).

```zig
pub fn compare(self: VectorClock, other: VectorClock) Order {
    var self_is_less = false;
    var other_is_less = false;
    
    // ... compare counters for all NodeIDs ...
    
    if (self_is_less and other_is_less) return .Concurrent;
    if (self_is_less) return .Less;
    if (other_is_less) return .Greater;
    return .Equal;
}
```

## 4. Conflict Resolution

When NomadFS detects a `.Concurrent` state:
1.  It preserves both versions of the file.
2.  It notifies the user (or the application) that a conflict occurred.
3.  Once the conflict is resolved (e.g., by choosing one version or merging them), a new vector clock is created that is greater than both conflicting clocks.

---

**Next Chapters:**
*   [Chapter 4.2: Merkle Tree Repair](./repair.md)
