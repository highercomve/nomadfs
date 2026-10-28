# Chapter 6.1: Security Model & Threat Analysis

This chapter states what NomadFS protects, against whom, and where the
protection stops. The handshake itself is explained step by step on the site
([Learn: Noise XXpsk3](https://nomadfs.foreachdeveloper.com/learn/noise/));
this chapter is the code-level summary.

## 1. Security Goals

1. **Confidentiality in transit**: every byte between two devices is
   encrypted with ChaCha20-Poly1305 inside a Noise session.
2. **Swarm admission**: only a device holding the 32-byte swarm key can
   complete a handshake (the key is the Noise `psk`).
3. **Device authentication**: each session carries a signature from the
   device's Ed25519 identity, bound to that session's handshake hash.
4. **Integrity of content**: every block is named by its SHA-256 hash and
   re-hashed whenever it is received or read from disk.
5. **Forward secrecy**: each session uses fresh ephemeral X25519 keys, so
   stealing long-term keys later does not decrypt recorded traffic.

**Not a goal today: confidentiality at rest.** Blocks are stored as plain
files named by their hex CID (`src/storage/engine.zig`), shared folders are
served straight from the original files (`src/fs/filestore.zig`), and the
swarm manifest is a JSON file (`<storage_path>.swarm.json`). Anyone who can
read a device's disk can read its data, and any device that holds a block (a
peer that fetched it, a [swarm backup device](../fs/swarm.md)) holds it in
the clear. There is no client-side or end-to-end encryption of blocks.

## 2. Who Can Do What

| Actor | Can | Cannot |
| :--- | :--- | :--- |
| Network observer | See that two IPs talk TCP; see the LAN announcement (`NMFS{"id":…,"port":…}`, UDP 5354) | Read or alter session traffic |
| Device without the swarm key | Complete message 1-2 of a handshake and learn the listener's static key and device hello | Finish the handshake; send any request |
| Holder of the swarm key (default policy) | Connect, browse every share, read every block it asks for, read and write the swarm folder, join the DHT | Impersonate a *paired* device (its transport key is pinned), forge blocks (CIDs are checked) |
| Holder of the swarm key, `require_trusted_devices = true` on the peer | Nothing on that peer unless its device ID is in the peer's trust store | - |
| Paired, trusted device | Everything above, plus have its `REVOKE` and `ROTATE_KEY` messages honoured | Revoke itself; replay an old rotation (epoch check) |

The default policy (`require_trusted_devices = false`) means **the swarm key
is the access control**: whoever has it is a full member. Device identities
are always verified, but only enforced when that option is on or when a
device is already paired (transport-key pinning).

## 3. Threat Table

| Threat | Mitigation | Status |
| :--- | :--- | :--- |
| Eavesdropping | ChaCha20-Poly1305 on every Noise frame (`src/net/transport/noise.zig`) | Implemented |
| Man-in-the-middle | `Noise_XXpsk3`: both static keys authenticated, swarm key mixed in | Implemented |
| Tampered or forged blocks | SHA-256 CID checked on `put`, `get`, `PUT_BLOCK` and remote loads | Implemented |
| Unknown device with the swarm key | Signed device hello; `require_trusted_devices` rejects unknown IDs | Implemented, strict policy opt-in |
| Stolen `node.key` posing as a paired device | Trust store pins the X25519 key; `TransportKeyMismatch` | Implemented |
| Leaked swarm key | Live rotation to paired devices (`ROTATE_KEY`, [7.3](./invites.md#2-swarm-key-rotation)) | Implemented (GUI-triggered) |
| Lost or compromised device | Signed revocation, pushed on dial and swept every 60 s ([7.3](./invites.md#3-revocation)) | Implemented |
| Data read from a stolen disk | None | Not protected |
| Sybil / DHT flooding by a key holder | None: any key holder can join the routing table | Risk |
| Eclipse | K-buckets keep long-lived peers; nothing else | Risk |
| Resource exhaustion | Handshake timeout (10 s), 64 Yamux streams × 256 KiB window per session, bounded manifest/trust store/ticket sizes | Partial; no rate limiting |

## 4. Cryptography

| Use | Primitive | Where |
| :--- | :--- | :--- |
| Session key exchange | X25519 | `noise.zig` |
| Session encryption | ChaCha20-Poly1305, 64-bit counter nonce | `noise.zig` `CipherState` |
| Handshake hash, HKDF | BLAKE2s-256 | `noise.zig` `SymmetricState` |
| Device identity, tickets, revocations, rotations, trust-store file | Ed25519 | `src/device/identity.zig` |
| Node ID, device ID, fingerprint | BLAKE2s-256 of a public key | `src/net/id.zig`, `identity.zig` |
| Content IDs | SHA-256 over tag byte + block bytes | `src/storage/dag/codec.zig` |
| Invite PSK | SHA-256(`"nomadfs-invite-v1:"` ‖ token) | `src/device/invite.zig` |

Protocol name: `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`.

## 5. The Swarm Key

A 32-byte secret, configured as `swarm_key` (64 hex characters, or a raw
32-byte string) and required to start a node.

- **Distribution**: by one-time invite (the key travels inside a Noise
  channel keyed by a token-derived PSK and is never shown), or by copying it
  into each `nomadfs.conf` by hand. See [7.3](./invites.md).
- **Rotation**: live. A device sends a new key, signed with its Ed25519
  identity, to every trusted device it can reach (`Node.rotateSwarmKey`,
  `ROTATE_KEY` RPC). `swarm_epoch` in the config records the current
  generation. See [7.3](./invites.md#2-swarm-key-rotation).
- **If stolen**: the thief is a full swarm member under the default policy.
  Rotate the key; devices that were never paired do not receive the new one.
- **If lost**: nothing is encrypted with it at rest, so no data is lost; a
  device without it simply cannot connect until it is re-invited.

## 6. Device Identity and Trust

Each device has an Ed25519 identity (`device.key`) separate from its X25519
transport key (`node.key`). Messages 2 and 3 of every handshake carry a
97-byte device hello signed over the handshake hash
(`src/device/auth.zig`). The receiver derives the device ID, checks the
pinned transport key of a paired device, and applies
`require_trusted_devices`. Details: [Chapter 6.2: Device Identity & Pairing](./pairing.md).

## 7. Not Implemented Yet

From [ROADMAP.md](../../ROADMAP.md) or noted as gaps in the code:

- **Encryption at rest** of the block store and manifest.
- **Capability-based permissions** per device or per module (the roadmap's
  `NomadModule` permissions, Phase 3).
- **Rate limiting** of connections and requests.
- **Sybil/eclipse resistance** in the DHT (peer reputation, admission limits).
- **Threshold revocation** (several trusted signers must agree), to limit
  what a single compromised trusted device can do.

---

**Next:** [Chapter 6.2: Device Identity & Pairing](./pairing.md) ·
[Back to the Internals Book](../README.md)
