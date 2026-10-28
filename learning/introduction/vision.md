# Vision and Philosophy

NomadFS is a filesystem for a world where your devices are always on the move.

## 1. The Problem: Roaming Devices

Most distributed storage (HDFS, Ceph, traditional RAID) assumes machines that
stay in one place, keep a fixed address and are almost always online. Personal
devices are different:
*   **Laptops** close in one city and open in another.
*   **Phones** switch between Wi-Fi and mobile data, and sleep most of the day.
*   **Home servers** sit behind residential routers and flaky connections.

A system built for a data centre treats a device going offline as a failure.
For personal devices, going offline is normal.

## 2. The NomadFS Goal

A private, decentralized filesystem for the devices one person (or one
household) owns, with three properties:

*   **Your files stay where they are.** NomadFS doesn't copy your folders into
    a cloud or onto every device. A shared folder is scanned into a Merkle
    tree. Its listing goes to the other devices, and a file's bytes move only
    when someone opens it, and only the chunks being read. Shared folders are
    served from the original files ([Chapter 5.1](../fs/shares.md)).
*   **Reading works offline after the first time.** Every block a device
    fetches is checked against its hash and kept in the local block store. A
    file opened once opens again without the other device.
*   **Writing never waits for the network.** The swarm folder, the one folder
    every device writes to, records an edit locally at once. Devices merge
    their listings whenever they meet ([Chapter 5.2](../fs/swarm.md)).

### Availability over coordination

In CAP terms NomadFS chooses **availability** and **partition tolerance**
for the swarm folder:

*   **Local writes.** An edit is a new entry in the device's own manifest,
    stamped with a Lamport clock. No other device has to answer.
*   **Eventual convergence.** Every 10 seconds each device pulls its peers'
    manifests and merges them. The merge is a state-based CRDT: any two
    devices that have seen the same edits end up with the same folder,
    whatever order the edits arrived in.
*   **No silent loss.** When two devices edit the same file without seeing
    each other's change, both versions are kept. One keeps the name, the
    other becomes `name (conflict from <device>).ext`, and every device picks
    the same names. A delete never beats a concurrent edit.

Shared folders don't need any of this: each belongs to one device, which is
the only writer.

## 3. Privacy by Default

NomadFS assumes the network is hostile:

*   **Private swarms.** Only devices with the swarm key complete a handshake.
    The key is the pre-shared key of a Noise `XXpsk3` handshake, so it never
    crosses the network ([Chapter 1.1](../net/transport/noise.md)).
*   **Encrypted, authenticated transport.** Every connection is encrypted
    with ChaCha20-Poly1305, with fresh ephemeral keys for each connection.
*   **Device identities.** Each device has an Ed25519 key, bound to every
    session by a signature. Devices can be paired, required to be trusted
    (`require_trusted_devices`), and revoked across the swarm.
*   **Easy, safe onboarding.** One-time invites carry a 128-bit token, never
    the swarm key itself. If the key may have leaked, it can be rotated to
    every trusted device ([Chapter 6.3](../security/invites.md)).

**What NomadFS does not do:** data is not encrypted at rest. Blocks, shared
files and the manifest are ordinary files on each device. Every device in a
swarm can read everything the swarm shares. Protect devices with disk
encryption, and give the swarm key only to devices you own.

## 4. Where This Is Heading

The [roadmap](../../ROADMAP.md) narrows the original idea (a general
distributed block store with a consistent hash ring and quorums) into a
**personal device mesh**. Its plans include directed sync and backup
policies, an always-on headless node that relays between devices behind
strict NATs, and more capabilities over the same encrypted connection.
Those are **not implemented yet**. Some code from the older design is still
in the tree but unused, such as the hash ring and vector clocks; see
[Chapter 4](../cluster/overview.md).
