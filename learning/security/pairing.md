# Device Identity & Pairing

## 1. Why Pairing Exists

The Swarm Key proves that a device may join *a* swarm, but it says nothing
about *which* device is connecting. Two consequences follow:

- every device that knows the Swarm Key is indistinguishable from any other;
- adding a laptop or phone means copying one shared secret around, and a leak
  cannot be traced back to a single device.

Pairing gives each device a long-lived Ed25519 identity and a way to hand its
public key to another device out of band: a signed `nomadfs://pair?...` ticket,
rendered as a QR code (GUI) or ASCII art (headless CLI). The peer stores the
identity in a trust store and can later require that identity during the
handshake.

The identity is now bound into the Noise handshake: both sides sign the
handshake transcript with their Ed25519 key, so a session is tied to the
device that opened it. Pairing and trust are still separate concerns - a
signature proves *which* identity is on the wire, while the trust store and
`require_trusted_devices` decide whether that identity is allowed.

## 2. Key Hierarchy

| Key | Algorithm | File | Lifetime | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| Swarm Key | 32-byte PSK | config | network-wide | Admission to the swarm |
| Device identity | Ed25519 | `device.key` | long-lived | Who the device is |
| Transport key | X25519 | `node.key` | per install / rotation | Noise handshake |

`device.key` contains an 8-byte magic (`NMDFSID1`) followed by the 32-byte
RFC 8032 seed. Storing the seed, rather than the expanded 64-byte secret,
matches RFC 8032 guidance and keeps backups small. The file is created with
mode `0600` and with `O_EXCL`: an existing identity is never silently replaced,
and a corrupt file is an error rather than an excuse to mint a new identity.

Derived values:

- **Device ID**: `BLAKE2s-256(identity_public_key)`. It is never transmitted as
  a separate field; every peer recomputes it, so a ticket cannot claim an ID
  that does not match its key.
- **Fingerprint**: first 8 bytes of the same digest, printed as
  `aaaa-bbbb-cccc-dddd`. This is the value humans compare out of band. It is a
  convenience, not a security boundary - the signature check is.

## 3. Ticket Format

A ticket is a URI with a fixed field order:

```
nomadfs://pair?v=1&p=<identity>&k=<transport>&n=<nickname>&a=<addresses>&e=<expiry>&s=<signature>
```

| Field | Encoding | Bounds |
| :--- | :--- | :--- |
| `v` | decimal | must be `1` |
| `p` | base64url, no padding | 32-byte Ed25519 public key |
| `k` | base64url, no padding | 32-byte X25519 transport key, pinned in the trust store |
| `n` | percent-encoded | 1-64 printable ASCII bytes |
| `a` | percent-encoded, comma separated | 1-8 `host:port` entries, 512 bytes total |
| `e` | decimal | Unix seconds, non-zero |
| `s` | base64url, no padding | 64-byte Ed25519 signature |

The signature covers the canonical URI through `e` - everything except `&s=`.
The canonical encoding is defined by the encoder itself:

- `p`, `k` and `s` use URL-safe base64 without padding;
- `n` and `a` percent-encode every byte outside `A-Z a-z 0-9 - . _ ~`;
- fields always appear in the order `v, p, k, n, a, e`.

Parsing decodes the fields, validates them, re-encodes the canonical form and
verifies the signature against it. This rejects unsigned fields, duplicate or
unknown parameters, truncated escapes, oversized values, and any ticket whose
signature was computed over a different byte sequence. Lenient input is fine
(e.g. `%54est` decodes to `Test`); what matters is that the reconstructed
canonical bytes match the signature.

Addresses are advisory hints, not proof of reachability. IPv4/hostname and
bracketed IPv6 literals are accepted; the port must be 1-65535.

## 4. Verification Flow

```
Device A                          Device B
--------                          --------
--pair
  load/create device.key
  load/create node.key
  build + sign ticket
  print URI + ASCII QR  ────────▶  --trust <uri>
                                     parse fields
                                     validate bounds
                                     recompute canonical URI
                                     Ed25519.verify(pubkey, canonical, sig)
                                     reject if expired
                                     trust.store: upsert by device_id
```

`--trust` rejects expired tickets with `error.ExpiredTicket`; a ticket is valid
while `now <= e`. The `k` transport key is recorded with the entry and pinned:
the paired device must present the same X25519 key in every later handshake
(see section 6), so a leaked or rotated `node.key` cannot take over a paired
identity without an explicit re-pairing. Default lifetime is 24 hours. The ticket is a bearer object
until it expires: anyone who photographs the QR code can present it. That is
acceptable for first contact on a trusted channel, and is why the fingerprint
is printed alongside the QR - compare it with the other device's screen.

`--devices` lists what the store currently trusts:

```
Trusted devices in /home/me/.nomadfs/trust.store:
  f712-ae38-4f35-7778  Test Laptop  added 1793040981  [f712ae38]
```

## 5. Trust Store

`trust.store` is a versioned text file:

```
NMDFSTR1
<device_id_hex>\t<public_key_b64>\t<added_at>\t<label_b64>\t<transport_key_b64>
```

- **Keyed by device ID**: re-pairing the same identity updates the label and
  the pinned transport key, and keeps the original `added_at` instead of
  creating a second entry. This is how a device rotates `node.key`.
- **Pinned transport key**: the fifth column records the X25519 key from the
  pairing ticket. Handshakes verify it again (section 6). Entries saved by
  older versions have four columns and stay unpinned until they re-pair.
- **Cross-checked on load**: the device ID must equal the hash of the stored
  public key. A mismatch means the file was edited or written by an
  incompatible version, and loading fails with `error.CorruptTrustStore`.
- **Bounded**: at most 64 entries (32 KiB file). Writes fail with
  `error.TrustStoreFull` rather than growing without limit.
- **Atomic**: the store is written to `<path>.tmp` with mode `0600` and then
  renamed over the original. A failed write leaves the old file intact.
- **Strict**: a missing file is an empty store; an unparsable file is an error.
  Silently discarding trust decisions is worse than refusing to start.

## 6. Handshake Binding

The Noise pattern stays `XXpsk3`. The Ed25519 identity travels inside the
existing encrypted handshake payloads rather than adding a new message:

| Message | Direction | Plaintext payload |
| :--- | :--- | :--- |
| 2 | responder -> initiator | `version(1) \|\| identity_pub(32) \|\| signature(64)` |
| 3 | initiator -> responder | `version(1) \|\| identity_pub(32) \|\| signature(64)` |

The signature covers `"nomadfs-device-auth-v1" || handshake_hash`, where the
handshake hash is captured immediately before the payload is encrypted. That
hash already commits to the ephemeral keys, both static X25519 keys, the PSK
and every previous message, so:

- a hello cannot be replayed into another session or moved to the other
  message;
- substituting the public key breaks the signature;
- a peer without the Swarm Key cannot produce a payload that decrypts at all.

Verification is unconditional: the payload length must be exact, the version
must be `1`, and the signature must verify. Afterwards
`NoiseStream.remote_device_id` holds the peer's device ID, derived from the
verified public key rather than trusted from the wire.

The signature proves *which* identity is speaking, and the trust store pins
which transport key belongs to it. Every `verifyHello` call also receives the
X25519 static key from the same handshake; a paired device whose Noise key
differs from the one in its ticket is rejected with
`error.TransportKeyMismatch` - even when `require_trusted_devices` is off,
because the pair was explicitly vouched for with that key. Only unpinned
entries (legacy files, never-paired devices) skip this check.

Trust is an additional policy:

```toml
[security]
require_trusted_devices = true
```

When enabled, a peer whose device ID is absent from `trust.store` is rejected
during the handshake with `error.UntrustedDevice`. It defaults to `false`
because a fresh install has an empty store and must still pair; the signature
check runs either way.

This is wire-incompatible: message 2 grew from 80 to 193 bytes and message 3
from 64 to 161, so both peers must run this version.

## 7. QR Output

Tickets are small enough for a medium-error-correction symbol. A typical ticket
(one address, 13-character nickname) fits in version 9-12, comfortably below
the version 40 ceiling; the encoder is validated against `zbarimg` for
versions 1-39 across all four error-correction levels.

The headless CLI prints ASCII art using half blocks:

- two module rows per terminal line;
- a 4-module quiet zone, as required by ISO/IEC 18004;
- `█`, `▀`, `▄` and space glyphs, with dark modules as ink by default.

Use `--address` to publish a reachable LAN address, since the default
(`127.0.0.1:<port>`) only works on the same host:

```sh
nomadfs --pair --address 192.168.1.5:9000
nomadfs --trust 'nomadfs://pair?v=1&p=...'
nomadfs --devices
nomadfs --revoke f712-ae38-4f35-7778
nomadfs --revoke f712ae384f357778...   # full device ID also works
```

`--revoke` accepts a device ID or fingerprint, case-insensitively, with or
without `0x` and with `-`, `:` or spaces ignored. A query that matches nothing
(or, in the unlikely case of a fingerprint collision, more than one entry) is
rejected instead of guessing. Removal is saved atomically like any other
trust-store write.

Revocation currently affects only the local store. Every node keeps its own
`trust.store`, so other peers continue to accept the removed device until
revocation propagation exists.

### Revocation Propagation

`--revoke` records the removal as a signed tombstone in the trust store
(`device_id`, `signer_id`, `at`). The signer is the device that ordered the
removal, and every tombstone it holds is pushed to peers as the
`REVOKE` RPC message, which each node sends opportunistically on connections
it dials itself (bootstrap peers, discovered peers).

A receiver applies a `REVOKE` only when:

1. the Ed25519 signature covers `revocation domain || revoked device || signer`,
   verified with the signer's key,
2. the signer is not the revoked device, and
3. the signer's device is itself in the receiver's trust store.

Everything else is refused rather than softened: an unknown signer, a broken
signature, or a self-revocation never touches entries. Honoring only locally
trusted signers keeps a compromised node from unilaterally pruning other
nodes' stores.

Tombstones persist in `trust.store` (`@`-prefixed lines, capped at 256), and
they do not block recovery: pairing again with a fresh, human-scanned ticket
clears the tombstone. Propagation is eventual - peers that were offline get
the tombstone the next time they dial a peer that still holds it; a periodic
anti-entropy sweep for revocations is future work.

## 8. Threat Notes & Next Steps

| Threat | Current mitigation | Gap |
| :--- | :--- | :--- |
| Unknown device joining | Handshake binds the Ed25519 identity; `require_trusted_devices` rejects unknown IDs | Policy defaults to off so fresh installs can pair |
| Tampered ticket | Ed25519 signature over canonical URI | - |
| Replay of an old ticket | 24-hour expiry, plus handshake identity check | Revocation propagation is opportunistic; offline peers learn tombstones on the next dial |
| Stolen ticket | Bearer until expiry | Fingerprint check is manual |
| Rotated or stolen `node.key` | Trust store pins the ticket's X25519 key and the handshake re-checks it | Re-pairing required after a rotation |
| Malicious trust file edit | ID/public-key cross-check, `0600` | No signature over the store itself |

Next slices: sign the trust store so a local edit cannot add an entry
silently, and add a periodic sweep so propagation no longer relies on one
side dialing the other first.

## 9. Source Map

| Path | Responsibility |
| :--- | :--- |
| `src/device/identity.zig` | Ed25519 identity, seed file, fingerprint |
| `src/device/pairing.zig` | Ticket construction, canonical form, parse/verify |
| `src/device/qr.zig` | QR encoder and ASCII renderer |
| `src/device/trust.zig` | Trust store, tombstones, revocation signature payload |
| `src/device/auth.zig` | Signed handshake hello, trust policy |
| `src/net/transport/noise.zig` | Carries and verifies the hello in messages 2 and 3 |
| `src/device/paths.zig` | Where `device.key` and `trust.store` live |
| `src/main.zig` | `--pair`, `--trust`, `--devices`, `--revoke` commands |
