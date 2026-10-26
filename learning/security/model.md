# Security Model & Threat Analysis

## 1. Security Goals

1.  **Confidentiality**: Data is readable only by nodes possessing the Swarm Key.
2.  **Integrity**: Data cannot be modified in transit or at rest without detection.
3.  **Authentication**: Only nodes proving possession of the Swarm Key can join, and each session is signed by an Ed25519 device identity.
4.  **Forward Secrecy**: Compromise of long-term keys does not compromise past sessions.

## 2. Threat Model

| Threat | Mitigation | Status |
| :--- | :--- | :--- |
| **Eavesdropping** | **ChaCha20-Poly1305** encryption on all streams. | ✅ Implemented |
| **Man-in-the-Middle** | **Noise_XXpsk3** handshake enforces mutual auth. | ✅ Implemented |
| **Tampering** | **Merkle DAGs** ensure content integrity by hash. | ✅ Implemented |
| **Unknown Device** | **Pairing tickets** carry a self-signed Ed25519 identity; the Noise handshake verifies a transcript signature, and `require_trusted_devices` rejects IDs missing from the trust store. Fingerprints are compared out of band. | ✅ Implemented (strict policy is opt-in) |
| **Sybil Attack** | **None currently**. A malicious actor with the Swarm Key can flood the DHT. | ⚠️ Risk |
| **Eclipse Attack** | **K-Buckets** prefer long-lived peers, but still vulnerable. | ⚠️ Risk |
| **DoS** | Basic **Yamux** flow control, but no strict rate limiting yet. | ⚠️ Risk |

## 3. Cryptography Standards

- **Device Identity**: Ed25519 signatures (tickets, trust store, handshake transcript)
- **Key Exchange**: X25519 (Elliptic Curve Diffie-Hellman)
- **Encryption**: ChaCha20-Poly1305 (Authenticated Encryption)
- **Hash Function**: BLAKE2s (for Noise state), SHA-256 (for Content Addressing)
- **Protocol**: Noise Protocol Framework (`Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`)

## 4. Swarm Keys

The security of the entire network relies on the **Swarm Key**. This is a 32-byte pre-shared key (PSK).
- **Distribution**: Must be done out-of-band (e.g., secure signal message, USB drive).
- **Rotation**: Currently requires a restart of all nodes with the new key.
- **Loss**: If lost, data remains encrypted but unrecoverable if no other node has it. If stolen, the attacker can join the network.

## 5. Future Work

- **Revocation Propagation**: Removals are local to one trust store today; a
  swarm-wide signed revocation list is still missing.
- **Signed Trust Store**: Entries are cross-checked but the file itself is not
  signed, so a local edit can still add a device.
- **Transport-Key Binding**: The ticket's X25519 key is not yet bound to the
  identity that presents it in the handshake.
- **Capability-Based Access Control**: Granular read/write permissions.
- **Connection Rate Limiting**: Defense against DoS.
- **Peer Reputation System**: Mitigation for Sybil/Eclipse attacks.
