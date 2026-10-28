# Chapter 4.5: Vector Clocks (and Why NomadFS Doesn't Use Them)

`src/cluster/vectors.zig` implements vector clocks, but they are **used only by that file's tests**. No file, manifest entry or message carries one. The one piece of NomadFS that does need to order concurrent edits, the swarm folder, uses Lamport versions with a short history instead. This chapter covers both.

## 1. What's in `vectors.zig`

A classic vector clock implementation:

```zig
pub const VectorClock = struct {
    entries: std.AutoHashMap(DeviceId, u64),
    pub fn increment(self: *VectorClock, device: DeviceId) !void;
    pub fn merge(self: *VectorClock, other: *const VectorClock) !void;
    pub fn compare(self: *const VectorClock, other: *const VectorClock) Ordering;
};
```

*   `compare` returns `.Equal`, `.Before`, `.After`, or `.Concurrent` (each has an entry the other doesn't, or one has a higher counter for one node and lower for another).
*   `merge` takes the per-node maximum. Assertions keep a clock under 1,000 entries.

`src/root.zig` imports the file only inside its `test` block, to compile and run these tests.

## 2. What the Swarm Folder Uses Instead

The swarm folder (`src/fs/manifest.zig`) is a state-based CRDT. Each entry carries:

```zig
pub const Version = struct { clock: u64, device: DeviceId };
// in Entry:
version: Version,
history: [8]?Version, // the last versions this one replaced
```

*   **Lamport clock**: each device keeps `clock` above every version it has seen; a local edit stamps `(clock + 1, this device)`.
*   **Causality from history**: when two versions of a path meet, if one lists the other in its `history` it descends from it and wins.
*   **Concurrent edits**: if neither does, both are kept. The higher version (clock, then device ID) keeps the path, and the other is renamed `name (conflict from <author>).ext`, computed identically on every device. A delete never beats a concurrent edit.
*   **Tombstone garbage collection**: Swarm-folder tombstones are garbage-collected after 90 days (`Manifest.pruneTombstones` in `src/fs/manifest.zig`, horizon of `90 * 24 * 60 * 60` seconds). A device that remains offline for longer than 90 days misses the tombstone before it is pruned, so when it reconnects, its older live entry will be merged as new and bring the deleted file back.

Compared with a vector clock this is constant-size per entry (one version plus eight), and it never has to grow with the number of devices. The price is that causality older than eight replaced versions is forgotten: a device that comes back after missing more than eight edits of the same file sees its old version as concurrent, so it is kept as a conflict copy rather than silently replaced. Full details: [The Swarm Folder](../fs/swarm.md); a diagram-led explanation is on the website: [The swarm folder CRDT](https://nomadfs.foreachdeveloper.com/learn/swarm-crdt/).

Shares need no clocks at all: each share has one writer, the device that shares it, and peers simply read its current root CID.

## 3. Not Implemented Yet

Per-file vector clocks, a "notify the user of a conflict" step and merged clocks on sync were part of an earlier design and do not exist. `vectors.zig` is kept but unused.

---

**Next Chapters:**
*   [The Swarm Folder](../fs/swarm.md)
