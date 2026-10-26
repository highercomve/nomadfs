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

The first implementation slice is deliberately additive: identities, tickets,
QR output and the trust store exist and are tested, while the Noise handshake
still authenticates with `XXpsk3` alone. Binding the identity into the
handshake is the next slice.

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
| `k` | base64url, no padding | 32-byte X25519 public key |
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
while `now <= e`. Default lifetime is 24 hours. The ticket is a bearer object
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
<device_id_hex>\t<public_key_b64>\t<added_at>\t<label_b64>
```

- **Keyed by device ID**: re-pairing the same identity updates the label and
  keeps the original `added_at` instead of creating a second entry.
- **Cross-checked on load**: the device ID must equal the hash of the stored
  public key. A mismatch means the file was edited or written by an
  incompatible version, and loading fails with `error.CorruptTrustStore`.
- **Bounded**: at most 64 entries (32 KiB file). Writes fail with
  `error.TrustStoreFull` rather than growing without limit.
- **Atomic**: the store is written to `<path>.tmp` with mode `0600` and then
  renamed over the original. A failed write leaves the old file intact.
- **Strict**: a missing file is an empty store; an unparsable file is an error.
  Silently discarding trust decisions is worse than refusing to start.

## 6. QR Output

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
```

## 7. Threat Notes & Next Steps

| Threat | Current mitigation | Gap |
| :--- | :--- | :--- |
| Unknown device joining | Identity ticket + fingerprint comparison | Handshake does not yet require a trusted identity |
| Tampered ticket | Ed25519 signature over canonical URI | - |
| Replay of an old ticket | 24-hour expiry | No revocation list beyond deleting the entry |
| Stolen ticket | Bearer until expiry | Fingerprint check is manual |
| Malicious trust file edit | ID/public-key cross-check, `0600` | No signature over the store itself |

Next slice: require a trusted Ed25519 identity during the Noise handshake,
bind the device ID to the transport key used in the ticket, and support
revocation propagation so a removed device cannot re-pair with its old ticket.

## 8. Source Map

| Path | Responsibility |
| :--- | :--- |
| `src/device/identity.zig` | Ed25519 identity, seed file, fingerprint |
| `src/device/pairing.zig` | Ticket construction, canonical form, parse/verify |
| `src/device/qr.zig` | QR encoder and ASCII renderer |
| `src/device/trust.zig` | Versioned trust store, atomic save |
| `src/device/paths.zig` | Where `device.key` and `trust.store` live |
| `src/main.zig` | `--pair`, `--trust`, `--devices` commands |
