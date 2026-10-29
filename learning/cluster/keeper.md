# Chapter 4.4: The Keeper (`src/cluster/keeper.zig`)

The keeper makes this device hold what it should. It replaced three copy loops that lived in
`src/fs/`: the swarm backup round, folder backup's own copying, and pushing a file to peers when it
was saved.

## 1. Providers say what, the keeper says how

`fs/` registers **providers**; the keeper knows nothing of what they are:

```zig
pub const Provider = struct {
    ctx: *anyopaque,
    /// The files this device should hold and doesn't yet, at most `max`.
    wantsFn: *const fn (ctx, allocator, out: *std.ArrayList(Want), max: usize) anyerror!void,
    /// `root` is now held in full (ok), or couldn't be copied this round.
    doneFn: *const fn (ctx, root: Cid, ok: bool) void,
};
pub const Want = struct { root: Cid, hints: [8]NodeID, hint_count: u8 };
```

The swarm folder is one (`SwarmFolder.keeperProvider`): it wants every live file on a swarm backup
device, else the files placement gives this device ([4.3](./placement.md)), with the author and the
other holders as hints, and records what was kept in `<manifest>.backup` so rounds stay cheap.

## 2. A round

One thread runs a round every 60 s, or soon after `wake()`: when a manifest sync brought changes,
the policy changed, or swarm backup was turned on. Each provider gives up to 64 wants; each is
copied, and the provider hears the result.

## 3. Copying a file (`copy`)

`copy(allocator, fetcher, store, root, hints, keep_going)` walks the DAG with four workers sharing a
stack:

* a block already held as file data (`StorageEngine.heldLeaf`, which reads one byte) is pinned
  without being read: copying a folder again reads only its index;
* anything else comes through the fetcher ([4.1](./fetcher.md)), so a copy spreads across holders
  like a read;
* every block is **pinned**: moved from the read cache into the kept area, against the quota
  (`StorageFull` past it);
* `keep_going` turning false stops it at the next block (`error.Cancelled`), so shutdown never
  waits for a whole copy;
* at most 2²⁰ blocks per DAG.

## 4. Folder backup

Folder backup still polls members' shares replies on its own 60 s round: deciding which members'
folders to keep, and merging each new version into the kept tree so the phone's deleted photos stay,
is meaning (`src/fs/backup.zig`). The copying is the keeper's: `FolderBackup.copyShare` calls
`cluster.keeper.copy` for the share's tree, then merges.

## 5. Repair

There is no separate repair loop. Placement depends on membership and the policy, so when a holder
is revoked or the `copies` setting changes, the next round on the devices that now win those files
copies them. A holder that is only offline is not replaced, to avoid churn when a laptop sleeps.

---

**Next:** [Chapter 4.5: The Mobile API's `put` and `get`](./repair.md)
