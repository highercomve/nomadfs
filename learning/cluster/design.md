# Chapter 4.5: The Distribution Layer, Restored (design)

> Status: **design**, being built on the `cluster-layer` branch. Chapters 4 to 4.4 describe
> the code as it is; this one describes where it is going and why.

## 1. What went wrong

The first design (`learning/dist/`, December 2025) was Dynamo-shaped: a consistent-hash
ring chose the N devices that hold each block, quorums (N, W, R) governed reads and
writes, vector clocks found conflicts and Merkle anti-entropy repaired missing copies.
The distribution layer knew where every block should be.

The October 2026 pivot (`ROADMAP.md`) dropped the global ring for good reasons: a hash
decides placement without regard to the device, so a phone would hold a third of the
swarm's blocks over mobile data, and users want *directed* copies ("phone photos to the
home server"), not everything everywhere.

What it should have kept is the distribution layer itself. Instead, features were built
top down, and each one chose its sources and made its copies inside `src/fs/`:

| Feature | Where it reads from (today) | How it copies (today) |
| :--- | :--- | :--- |
| Browse, mount, app viewer | the sharing device only (`fs.Remote`) | n/a |
| Swarm folder reads | the author, then every known device in turn (`MultiRemote`, `ReadAhead`) | n/a |
| Swarm backup | the author, then every known device | `SwarmFolder.backupRound` |
| Folder backup | the sharing device | `FolderBackup.copyShare` |
| `swarm_replicas` | n/a | push at save (`SwarmFolder.addFile`) |
| `BlockManager.get` | DHT providers, one at a time (mobile C API only) | `BlockManager.replicate` at put |

So `src/cluster/` became a bypass: no layer knows who holds a file, a read uses one
device at a time, a copy that disappears is never made again, and three loops copy data
three ways.

## 2. The layers

| Layer | Owns | Does not own |
| :--- | :--- | :--- |
| `src/fs/` (meaning) | shares and their scans, the swarm manifest (CRDT), folder trees, the backup *merge* (keep what the source deleted), read-ahead (*which* chunks come next), the mount | where chunks come from, who keeps copies |
| `src/cluster/` (distribution) | **placement** (who should hold what), the **holder registry** (who holds what), the **fetcher** (where each chunk comes from), the **keeper** (make this device hold what placement assigns it, and repair) | names, folders, what a file means |
| `src/net/` (transport) | connections, Noise, Yamux, the DHT, relays, trust at the connection | content |

The rule: `fs/` says *what* it needs ("these bytes of this root; the author is X");
`cluster/` decides *where from* and *who keeps it*. `fs/` never opens a connection to
fetch a block, and never copies a DAG itself.

## 3. One question for every feature: who holds this root?

A file's chunks have the same CIDs wherever it lives: the photo in a phone's Camera
share, in Plex's backup of that share, and in the swarm folder are the same leaves. So
"who holds this root" is one question, answered from four sources:

1. **Hints from `fs/`**: the author of a swarm entry, the device sharing a folder.
2. **Roles**: swarm backup devices hold every swarm file; folder backup devices list the
   shares they hold (the SHARES `backup` field).
3. **Announcements**: a device that keeps a whole DAG (pinned) announces its root
   (provider records, re-announced before they expire), and answers a cheap "do you have
   this root?".
4. **Placement**: who *should* hold it (below); a likely holder even before it says so.

Every holder keeps the whole DAG, so one record per root is enough; a device that only
cached some chunks while reading is a bonus source, not a holder.

## 4. Placement: directed, not hashed

Placement replaces the ring's preference list with roles and policy, decided the same
way on every device so they agree without asking each other:

| Content | Held by |
| :--- | :--- |
| A shared folder, not marked for backup | its device only (the pivot: not everything everywhere) |
| A shared folder marked for backup | its device + every folder backup device, on Wi-Fi, kept after deletion at the source |
| A swarm folder file | its author + every swarm backup device + up to **N** devices that accept copies |

**N** is one swarm-wide setting, signed by the member who sets it and spread like
membership (newest wins). The N devices for a file are chosen by **rendezvous hashing**
of the file's root over the members that accept copies: each device can compute the
list alone, and adding or removing a device moves only its own share of files. A device
may refuse copies (phones by default) and caps them with its quota.

## 5. The fetcher

Every read goes through `cluster.Fetcher`: the mount, Browse, the app's viewer and
downloads, the swarm folder, and the keeper's copies.

- It takes a root, the CIDs wanted and the hints, and asks the registry for holders.
- It keeps several requests in flight per holder, measures each holder's throughput as
  blocks arrive, and gives more work to the faster ones; a holder that stalls loses its
  work to the others, without a timeout per chunk.
- It remembers misses ("doesn't have this root") for a while, so a device without the file
  costs one round trip, not one per chunk.
- It prefers holders not on mobile data, and the local store above all.
- Every block is verified against its CID, as today, so mixing sources is safe.

`fs.ReadAhead` stays in `fs/`: it decides which chunks a player needs next and hands them
to the fetcher; it no longer fetches.

## 6. The keeper

One loop in `cluster/` replaces the swarm backup round, `FolderBackup`'s copying and the
`swarm_replicas` push:

1. Ask placement what this device should hold.
2. Compare with what it holds; fetch the difference through the fetcher (pinned, in the
   kept area), on Wi-Fi where the policy says so.
3. Announce what it holds.
4. When a holder is gone for long enough, the next device in that file's rendezvous list
   takes its place: that is the repair the first design called anti-entropy.

The folder-backup merge (`fs/backup.zig`) stays in `fs/`: the keeper copies a share's
blocks, then `fs/` merges the new tree into the kept one.

## 7. Stages

1. **Fetcher with hints.** `cluster.Fetcher`; every read path in `fs/`, the mount and the
   app goes through it, with holders from hints and roles (no protocol change). Streams
   use every known holder at once.
2. **Holder registry.** Root announcements and re-announcing, "do you have this root?",
   remembered misses.
3. **Placement and keeper.** The swarm-wide N with opt-out; swarm backup, folder backup
   and `swarm_replicas` folded into the keeper; repair when holders disappear.
4. **Clean-up.** Remove `fs.Remote`'s fetching, `MultiRemote`, the old copy loops and
   `BlockManager.get`'s own source loop; this chapter becomes the description of the code.

Each stage brings cluster tests; the first: a stream from three holders at different
speeds, one of which disappears mid-stream.

---

**Next Chapters:**
*   [Chapter 4: Block Exchange & Replication](./overview.md)
*   [Chapter 5.1: Shared Folders](../fs/shares.md)
*   [Chapter 5.2: The Swarm Folder](../fs/swarm.md)
