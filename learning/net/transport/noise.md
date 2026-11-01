# Chapter 1.1: The Noise Protocol (Session Encryption)

Every TCP connection in NomadFS is encrypted with Noise, implemented
from scratch in `src/net/transport/noise.zig` on top of Zig's `std.crypto`.

## 1. The Protocol: `Noise_XXpsk0_25519_ChaChaPoly_BLAKE2s`

This string is the protocol name. `SymmetricState.init` hashes it into the
initial chaining key and handshake hash. NomadFS then mixes the prologue
`nomadfs-noise-v3` into the hash. v3 (0.4.0) is the only supported
handshake: v2 (`XXpsk0`, until 0.3.18) fails its first tag check. All
devices must be updated together.
Each `e` token is followed by both `MixHash(e)` and `MixKey(e)`, as required
by the Noise PSK modifier. Cacophony has no XXpsk0 vector, so the test uses
its inputs with expected bytes from snow 0.9, an independent implementation,
including the transport keys.

*   **XX**: both sides transmit their static public key during the handshake,
    encrypted. Neither needs to know the other's key in advance.
*   **psk0**: the Swarm Key is mixed into the key material before message 1.
    A peer without the Swarm Key fails the first tag check and gets no
    answer.
*   **25519**: X25519 Diffie-Hellman (`std.crypto.dh.X25519`).
*   **ChaChaPoly**: ChaCha20-Poly1305 AEAD (`std.crypto.aead.chacha_poly`).
*   **BLAKE2s**: BLAKE2s-256 for the handshake hash, and HMAC-BLAKE2s HKDF for
    key derivation.

## 2. Key Concepts and Types

| Type | Role |
| :--- | :--- |
| `KeyPair` | an X25519 key pair. The node's *static* (transport) key lives in `node.key`, exactly 64 bytes (`public_key (32) ++ private_key (32)`), with mode `0600`. Key loading validates that the private key derives the public key (`recoverPublicKey`). Secret keys and key buffers are zeroed with `std.crypto.secureZero` on generation, load, save, and `NoiseStream.deinit`. `saveToFile` never overwrites an existing file. |
| `CipherState` | key `k` plus a 64-bit nonce counter `n`; `encryptWithAd` / `decryptWithAd`. The nonce is 4 zero bytes followed by `n` little-endian. |
| `SymmetricState` | chaining key `ck`, handshake hash `h`, and a `CipherState`. `mixKey`, `mixHash`, `mixKeyAndHash` (for the PSK), `encryptAndHash`, `decryptAndHash` and `split`. |
| `HandshakeState` | local static `s`, ephemeral `e`, remote `rs`/`re`, the PSK, the role, and the `device_auth.Authenticator`. |
| `NoiseStream` | the finished connection: send and receive `CipherState`s, `remote_static`, `remote_device_id`, final `handshake_hash`, and a read buffer. |

*   **Static key (`s`)**: the long-lived transport key. The DHT node ID is
    BLAKE2s-256 of its public half (`NodeID.fromPublicKey`).
*   **Ephemeral key (`e`)**: generated per handshake, which gives forward
    secrecy.
*   **Deadlines and timeouts**: handshake steps are bounded by a 10-second
    deadline (`handshake_timeout_ms = 10_000`); socket reads and writes honor
    deadlines, aborting if the peer stalls.

## 3. The Handshake Messages

Every message begins with a 2-byte big-endian length prefix. A message not
exactly the expected size (`error.HandshakeFailed`).

```mermaid
sequenceDiagram
    participant I as Dialer (initiator)
    participant R as Listener (responder)
    I->>R: msg 1 (48 B): psk, e + empty payload tag
    R->>I: msg 2 (193 B): e, ee, s, es + device hello
    I->>R: msg 3 (161 B): s, se + device hello
    Note over I,R: split() gives two CipherStates, one per direction
```

### Message 1: `-> psk, e` (`buildMessage1` / `consumeMessage1`)
Both sides first call `mixKeyAndHash(swarm_key)`. The initiator generates
`e` and sends its 32-byte public key in the clear. `mixHash(e.pub)` binds it
to the transcript, and `mixKey(e.pub)` derives the cipher key from the
chaining key, which already holds the swarm key. Encrypting an empty payload
adds a 16-byte tag, making message 1 48 bytes. The responder checks the tag
before anything else: a dialer without the swarm key fails here, and the
responder closes the connection without sending message 2.

### Message 2: `<- e, ee, s, es` (`writeMessage2` / `readMessage2`)
1.  **`e`**: the responder's ephemeral public key (32 B), mixed into `h` and the chaining key.
2.  **`ee`**: `mixKey(DH(e_I, e_R))`. This replaces the key derived from `e`.
3.  **`s`**: the responder's static key, encrypted (32 + 16-byte tag = 48 B).
4.  **`es`**: `mixKey(DH(e_I, s_R))`.
5.  **Payload**: the responder's encrypted **device hello** (97 + 16 B).

### Message 3: `-> s, se` (`writeMessage3` / `readMessage3`)
1.  **`s`**: the initiator's static key, encrypted (32 + 16 B).
2.  **`se`**: `mixKey(DH(s_I, e_R))`.
3.  **Payload**: the initiator's encrypted **device hello** (97 + 16 B).

**Verification.** A responder with a different swarm key derives a different
key from the start, so the tag on message 1's empty payload fails and the
connection is closed. A responder with a different key fails the initiator
the same way, at message 2.

**Nothing leaks before the PSK check.** Every key, from message 1 on,
depends on the swarm key. A scanner without it gets no message 2, so it
learns neither the responder's static key nor its device identity. With
`psk3` (v2, until 0.3.18) message 2 was encrypted only with keys from `ee`
and `es`, and any dialer could read who it had reached.

## 4. Device Identity: the Device Hello (`src/device/auth.zig`)

The X25519 key is a *transport* key. A device's lasting identity is an
Ed25519 key (`device.key`, see `src/device/identity.zig`). Messages 2 and 3
carry a 97-byte hello that ties the two together:

```
hello = version (1, = 1) ‖ Ed25519 public key (32) ‖ signature (64)
signature = Ed25519.sign("nomadfs-device-auth-v1" ‖ h)
```

`h` is the handshake hash at the moment the hello is encrypted. It includes
the PSK in both messages. The receiver captures `h` before
decrypting the payload and calls `Authenticator.verifyHello(hello, h, rs)`:

1. checks the version byte and length (`error.InvalidDeviceHello`);
2. verifies the signature over the same domain string and `h`. A hello from
   another session fails here, because `h` covers both ephemeral keys;
3. computes the device ID as BLAKE2s-256 of the Ed25519 public key;
4. if the trust store has an entry for that device, requires its pinned
   transport key to equal the handshake's static key `rs`
   (`error.TransportKeyMismatch`). An entry with no recorded transport key
   (all zeros) is not checked;
5. if `require_trusted` is set (config `require_trusted_devices = true`),
   requires the device to be trusted (`error.UntrustedDevice`).

`NoiseStream.handshake` accepts a null authenticator (tests and embedded
use). In that case it generates a throwaway Ed25519 identity, so the hello
exchange always happens.

The trust store, pairing tickets and revocation are covered in
[Device Identity & Pairing](../../security/pairing.md). Invites,
which run this same handshake with a token-derived PSK, are covered in
[Invites](../../security/invites.md).

## 5. After the Handshake: Transport Frames

`split()` derives two `CipherState`s. The initiator sends with the first and
receives with the second; the responder does the opposite. Each encrypted
frame on the socket looks like this:

```
[u16 BE length][ciphertext ‖ 16-byte Poly1305 tag]
```

*   `NoiseStream.write` splits data into chunks of at most **65,519 bytes of
    plaintext** (`max_payload = 65535 - 16`). Each chunk becomes one frame
    of at most 65,535 bytes, excluding the two-byte length prefix.
*   `NoiseStream.read` reads one frame (it refuses frames shorter than the
    tag or longer than its 65,535 + 16-byte buffer), decrypts it with an
    empty associated data, and buffers whatever the caller didn't take.
*   The nonce is the 64-bit frame counter. The reserved maximum counter is
    rejected with `error.NonceExhausted`.
*   On `NoiseStream.deinit`, cipher keys and read/write buffers are zeroed with
    `std.crypto.secureZero`.

## 6. Why Noise vs. TLS?

| Feature | TLS 1.3 | Noise (XXpsk0) in NomadFS |
| :--- | :--- | :--- |
| **Identity** | X.509 certificates, a CA | raw public keys; an Ed25519 device key signs the transcript |
| **Membership** | not part of TLS | the swarm key, as a PSK |
| **Complexity** | ASN.1, X.509, many cipher suites | one fixed suite, a few hundred lines of Zig |

The swarm key never crosses the network. It can be replaced on every
trusted device with a signed `ROTATE_KEY` message
(`src/device/rotation.zig`, see the [Security Model](../../security/model.md)).

---

**Next Chapters:**
*   [Chapter 1.2: Multiplexing with Yamux](./yamux.md)
*   [Chapter 1.3: Testing Network Logic](./testing.md)
