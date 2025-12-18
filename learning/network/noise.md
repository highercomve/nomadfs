# Chapter 1.1: Security & The Noise Handshake

NomadFS enforces a **Private Swarm** model. Only peers who possess a pre-shared **Swarm Key** can join the network and see the data. This is achieved using the **Noise Protocol Framework**.

## 1. The Protocol: `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`

This is our cryptographic "cipher suite". It defines how keys are exchanged, how data is encrypted, and how we verify identities.

*   **XX**: Mutual Authentication (both sides prove their identity).
*   **psk3**: A "Pre-Shared Key" modifier at the end of the handshake for swarm membership.
*   **25519**: X25519 Elliptic Curve Diffie-Hellman (ECDH).
*   **ChaChaPoly**: ChaCha20-Poly1305 (Authenticated Encryption).
*   **BLAKE2s**: For hashing and key derivation.

## 2. Key Concepts

### Diffie-Hellman (DH) Exchange
The math that allows two people to agree on a secret number without an eavesdropper knowing what it is.
*   **Shared Secret (`ss`)** = `DH(MyPrivateKey, TheirPublicKey)`.
*   Both sides end up with the same `ss`.

### Key Types
*   **Static Key (`s`)**: Your node's long-term identity. Your "Node ID" is derived from this.
*   **Ephemeral Key (`e`)**: A temporary key generated for a single connection. This provides **Forward Secrecy**.

## 3. The Handshake Process

The handshake consists of 3 messages.

### Message 1: `-> e` (Initiator sends Ephemeral Key)
The Initiator sends their public ephemeral key.
*   **Hash Update**: `h = BLAKE2s(h || e_pub)`. This binds the key to the connection transcript.

### Message 2: `<- e, ee, s, es` (Responder's turn)
The Responder sends their ephemeral key and encrypted static key.
1.  **`ee` (DH)**: `ss = DH(I_e, R_e)`. This secret is mixed into the **Chaining Key (`ck`)** using HKDF.
2.  **Key Ratchet**: This derivation produces a new encryption key `k`.
3.  **`s` (Encrypted)**: The Responder encrypts their Static Key (`s_pub`) with `k` and sends it.
4.  **`es` (DH)**: `ss = DH(I_e, R_s)`. This binds the Initiator's ephemeral session to the Responder's identity.

### Message 3: `-> s, se, psk` (Initiator's proof)
The Initiator sends their identity and the swarm authentication.
1.  **`s` (Encrypted)**: Initiator sends their Static Key.
2.  **`se` (DH)**: `ss = DH(I_s, R_e)`. Binds the Responder's ephemeral session to the Initiator's identity.
3.  **`psk` (Mix)**: The **Swarm Key** is mixed into the encryption state.
4.  **Verification**: If the Responder doesn't have the same Swarm Key, they cannot decrypt the final authentication tag in this message. The connection fails.

## 4. Why Noise vs. TLS?

| Feature | TLS 1.3 | Noise (XXpsk3) |
| :--- | :--- | :--- |
| **Identity** | Certificates (CA) | Raw Public Keys |
| **Complexity** | High (ASN.1, X.509) | Low (Fixed binary) |
| **Trust** | Centralized | Decentralized |

In NomadFS, your **Public Key IS your identity**. We don't need a certificate authority (like GoDaddy) to tell us who you are; the network verifies your signature directly.
