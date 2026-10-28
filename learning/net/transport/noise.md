# Chapter 1.1: Security & The Noise Handshake

NomadFS uses a **private swarm** model: only peers that hold the same 32-byte
**swarm key** can complete a connection. The mechanism is the
[Noise Protocol Framework](https://noiseprotocol.org/noise.html), implemented
from scratch in `src/net/transport/noise.zig` on top of Zig's `std.crypto`.

> Diagram and plain-language walkthrough:
> [Learn: Noise XXpsk3](https://nomadfs.foreachdeveloper.com/learn/noise/).

## 1. The Protocol: `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`

This string is the protocol name. `SymmetricState.init` hashes it into the
initial chaining key and handshake hash.

*   **XX**: both sides transmit their static public key during the handshake,
    encrypted. Neither needs to know the other's key in advance.
*   **psk3**: a pre-shared key is mixed in at the end of message 3 (the swarm
    key, or for invites a key derived from the invite token).
*   **25519**: X25519 Diffie-Hellman (`std.crypto.dh.X25519`).
*   **ChaChaPoly**: ChaCha20-Poly1305 AEAD (`std.crypto.aead.chacha_poly`).
*   **BLAKE2s**: BLAKE2s-256 for the handshake hash, and HMAC-BLAKE2s HKDF for
    key derivation.

## 2. Key Concepts and Types

| Type | Role |
| :--- | :--- |
| `KeyPair` | an X25519 key pair. The node's *static* (transport) key lives in `node.key`, 64 bytes, mode `0600`. `loadFromFile` checks that the public key matches the private one; `saveToFile` never overwrites. |
| `CipherState` | key `k` plus a 64-bit nonce counter `n`; `encryptWithAd` / `decryptWithAd`. The nonce is 4 zero bytes followed by `n` little-endian. |
| `SymmetricState` | chaining key `ck`, handshake hash `h`, and a `CipherState`. `mixKey`, `mixHash`, `mixKeyAndHash` (for the PSK), `encryptAndHash`, `decryptAndHash` and `split`. |
| `HandshakeState` | local static `s`, ephemeral `e`, remote `rs`/`re`, the PSK, the role, and the `device_auth.Authenticator`. |
| `NoiseStream` | the finished connection: send and receive `CipherState`s, `remote_static`, `remote_device_id`, and a read buffer. |

*   **Static key (`s`)**: the long-lived transport key. The DHT node ID is
    BLAKE2s-256 of its public half (`NodeID.fromPublicKey`).
*   **Ephemeral key (`e`)**: generated per handshake, which gives forward
    secrecy.

## 3. The Handshake Messages

Every handshake message is written as a **u16 big-endian length** followed by
the message. `readHandshakeMessage` rejects any message whose length isn't
exactly the expected size (`error.HandshakeFailed`).

```mermaid
sequenceDiagram
    participant I as Dialer (initiator)
    participant R as Listener (responder)
    I->>R: msg 1 (32 B): e
    R->>I: msg 2 (193 B): e, ee, s, es + device hello
    I->>R: msg 3 (161 B): s, se, psk + device hello
    Note over I,R: split() gives two CipherStates, one per direction
```

### Message 1: `-> e` (`writeMessage1` / `readMessage1`)
The initiator generates `e` and sends its 32-byte public key in the clear.
`mixHash(e.pub)` binds it to the transcript.

### Message 2: `<- e, ee, s, es` (`writeMessage2` / `readMessage2`)
1.  **`e`**: the responder's ephemeral public key (32 B), mixed into `h`.
2.  **`ee`**: `mixKey(DH(e_I, e_R))`. From here on there is an encryption key.
3.  **`s`**: the responder's static key, encrypted (32 + 16-byte tag = 48 B).
4.  **`es`**: `mixKey(DH(e_I, s_R))`.
5.  **Payload**: the responder's encrypted **device hello** (97 + 16 B).

### Message 3: `-> s, se, psk` (`writeMessage3` / `readMessage3`)
1.  **`s`**: the initiator's static key, encrypted (48 B).
2.  **`se`**: `mixKey(DH(s_I, e_R))`.
3.  **`psk`**: `mixKeyAndHash(swarm_key)`. The PSK feeds both the chaining key
    and the handshake hash.
4.  **Payload**: the initiator's encrypted device hello (97 + 16 B).

**Verification.** A responder with a different swarm key derives a different
key after `psk`, so decrypting the message 3 payload fails its Poly1305 tag
check. The error is logged as `Message 3 Decrypt (payload/psk verify)`, and
the connection is closed.

**What leaks before the PSK check.** The responder's static key and device
hello in message 2 are encrypted only with keys from `ee` and `es`, before
any PSK. An initiator that doesn't hold the swarm key can still learn which
device it reached. The initiator's static key in message 3 is likewise
decrypted before the PSK is mixed in, but its device hello comes after.

## 4. Device Identity: the Device Hello (`src/device/auth.zig`)

The X25519 key is a *transport* key. A device's lasting identity is an
Ed25519 key (`device.key`, see `src/device/identity.zig`). Messages 2 and 3
carry a 97-byte hello that ties the two together:

```
hello = version (1, = 1) ‖ Ed25519 public key (32) ‖ signature (64)
signature = Ed25519.sign("nomadfs-device-auth-v1" ‖ h)
```

`h` is the handshake hash at the moment the hello is encrypted. In message 3
that hash already includes the PSK. The receiver captures `h` before
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

*   `NoiseStream.write` splits data into chunks of at most **1024 bytes of
    plaintext**. Each chunk becomes one frame of at most 1040 bytes.
*   `NoiseStream.read` reads one frame (it refuses frames shorter than the
    tag or longer than its 65,535 + 16-byte buffer), decrypts it with an
    empty associated data, and buffers whatever the caller didn't take.
*   The nonce is the 64-bit frame counter. `CipherState.rekey()` exists but
    nothing calls it.

## 6. Why Noise vs. TLS?

| Feature | TLS 1.3 | Noise (XXpsk3) in NomadFS |
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
