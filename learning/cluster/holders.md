# Chapter 4.2: Holders (`src/cluster/holders.zig`)

The fetcher picks among holders; something has to say who they might be. `Holders` answers *who
probably holds this file*, learned only from messages devices already exchange. It never announces
anything and never asks anyone.

## 1. What it learns, and from where

| Fact | Learned from | Recorded by |
| :--- | :--- | :--- |
| A device's **roles**: swarm backup device (bit 0), accepts copies (bit 1), on mobile data (bit 2) | one byte at the end of every PING and PONG, which devices send anyway | the discovery node, per device, 256 entries, least recently heard out |
| "Device B keeps copies of device A's folders" | the `backup` field of a `GET_SHARES` reply, fetched anyway when browsing and by folder backup rounds | `noteKeeps(B, A)`, 256 entries, forgotten after 7 days unseen |

The second fact is meaning: only `fs/` knows what a shares reply's backup field says. So `fs/`
decodes it (`fs/remote.zig` `Remote.shares`), maps each held backup's owner from a device ID to its
transport node ID through the trust store, and tells the cluster layer just the fact:
`holders.noteKeeps(holder, origin)`. The cluster layer never sees a share.

Roles come from the node's own state: `swarm_backup`, `accept_copies` and whether the device is on
Wi-Fi or wired (refreshed every 30 s). A revoked device is forgotten at once, as a holder and as an
origin.

## 2. The lists it gives

```zig
pub fn forOrigin(self: *Holders, origin: NodeID, out: *[max_holders]NodeID) []NodeID
pub fn forSwarm(self: *Holders, author: NodeID, out: *[max_holders]NodeID) []NodeID
```

* **`forOrigin`**, for a shared folder's files: the sharing device, then the devices noted as
  keeping copies of its folders. Browse, the mount, the viewer, downloads and file details read
  shares through `fs.remote.readShareAt`, which asks for this list. The sharing device can be off:
  a phone's backed-up photos open from the backup device.
* **`forSwarm`**, for a swarm file: the author, then the devices whose roles say *swarm backup*
  (they keep every file), then the other known devices as a reserve.

In both, devices on mobile data go last, this device is never listed, and the list stops at eight.
The swarm folder adds the devices placement gives the file right after the author
([4.3](./placement.md)).

A wrong guess is cheap: the fetcher's misses ([4.1](./fetcher.md)) make a device without the file
cost a few round trips once.

---

**Next:** [Chapter 4.3: Placement and the Swarm Policy](./placement.md)
