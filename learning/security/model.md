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
| Holder of the swarm key (default policy) | Connect, browse every share, read every block it asks for, read and write the swarm folder, join the DHT (it can't write to another device's store: devices only keep blocks they asked for) | Impersonate a *paired* device (its transport key is pinned; it can claim any nickname, so the app and the mount mark unpaired devices as such and never name them like a paired device), forge blocks (CIDs are checked) |
| Holder of the swarm key, `require_trusted_devices = true` on the peer | Nothing on that peer unless its device ID is in the peer's trust store | - |
| Paired, trusted device | Everything above, plus have its `REVOKE` and `ROTATE_KEY` messages honoured | Revoke itself; replay an old rotation (epoch check) |

The default policy (`require_trusted_devices = false`) means **the swarm key
is the access control**: whoever has it is a full member. A leaked swarm key
is LAN/Tailscale-scoped unless the user turned UPnP on. Device identities
are always verified, but only enforced when that option is on or when a
device is already paired (transport-key pinning). Under either policy
(`require_trusted_devices = false` or `true`), a device whose ID matches a
tombstone in the local trust store is rejected with `UntrustedDevice`.

## 3. Threat Table

| Threat | Mitigation | Status |
| :--- | :--- | :--- |
| Eavesdropping | ChaCha20-Poly1305 on every Noise frame (`src/net/transport/noise.zig`) | Implemented |
| Man-in-the-middle | `Noise_XXpsk3`: both static keys authenticated, swarm key mixed in | Implemented |
| Tampered or forged blocks | SHA-256 CID checked on `put`, `get` and every fetched block | Implemented |
| Unknown device with the swarm key | Signed device hello; `require_trusted_devices` rejects unknown IDs | Implemented, strict policy opt-in |
| Stolen `node.key` posing as a paired device | Trust store pins the X25519 key; `TransportKeyMismatch` | Implemented |
| Leaked swarm key | Live rotation to paired devices (`ROTATE_KEY`, [7.3](./invites.md#2-swarm-key-rotation)) | Implemented (GUI-triggered) |
| Lost or compromised device | Signed revocation, pushed on dial and swept every 60 s ([7.3](./invites.md#3-revocation)) | Implemented |
| Port published to the Internet by the router | UPnP is off by default; when on: 1-hour renewed lease, responder must be on-link, deleted on stop | Implemented (opt-in) |
| Admitting a device through any member | Signed `ADMIT` vouches accepted only from trusted members; tombstones newer than a vouch win; known entries are never changed from the network | Implemented; any single member can admit (as any member can revoke) |
| Spoofed device nickname (an unpaired device claims a paired device's name) | Names of paired devices come from the local trust store; unpaired devices always carry a device-ID suffix and a "Not paired" badge (`src/fs/device_names.zig`) | Implemented |
| Data read from a stolen disk | None | Not protected |
| Sybil / DHT flooding by a key holder | None: any key holder can join the routing table | Risk |
| Eclipse | K-buckets keep long-lived peers; nothing else | Risk |
| Resource exhaustion | Handshake timeout (10 s), 64 Yamux streams × 1 MiB window per session (up to 64 MiB buffered), storage quota (`quota_mb`), read cache limit (`cache_mb`, LRU), capped block transfer size (`max_put_block_len`), bounded manifest/trust store/ticket sizes | Partial; no rate limiting |

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

Protocol name: `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s` (v2).

> NomadFS uses standard `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s` with the prologue `nomadfs-noise-v2`. Each ephemeral public key is mixed into both the transcript hash and chaining key. The handshake and transport keys are checked against the published Cacophony vector. v2 is the only accepted handshake; earlier 32-byte first messages are rejected, so all devices must be updated together.

## 5. The Swarm Key

A 32-byte secret, configured as `swarm_key` (64 hex characters, or a raw
32-byte string) and required to start a node. 32-character hexadecimal strings
are rejected as ambiguous (`expected 64 hex characters`).

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

> Pairing tickets bind an identity to a transport key, nickname, addresses and expiry. Human-mediated imports still require a fingerprint comparison: a copied ticket does not prove the presenter's identity. Invites always require proof of possession through the signed Noise device hello, and each ticket must match that session identity. The trust store records the highest accepted ticket expiry and refuses smaller expiries, preventing rollback of a newer transport-key pin. Ticket emitters must keep their fixed 24-hour lifetime; expiry is the freshness sequence. Only NMDFSTR2 stores are read. A retired NMDFSTR1 store is backed up once and starts empty; devices must re-join.

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
