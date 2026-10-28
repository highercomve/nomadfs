# Chapter 6.3: Invites, Key Rotation & Revocation

[Chapter 6.2](./pairing.md) covered the building blocks: the Ed25519 device
identity, signed pairing tickets and the trust store. This chapter covers the
three flows built on them:

1. **Invites**: how a new device gets the swarm key and becomes trusted,
   without anyone copying the key around.
2. **Swarm key rotation**: how a possibly leaked key is replaced on every
   paired device, live.
3. **Revocation**: how removing a device on one machine spreads to the rest.

User-facing guide: [Connecting devices](https://nomadfs.foreachdeveloper.com/docs/connecting-devices/).
Handshake background: [Learn: Noise XXpsk3](https://nomadfs.foreachdeveloper.com/learn/noise/#invites).

---

## 1. One-Time Invites (`src/device/invite.zig`)

### 1.1 The code

```
nomadfs://invite?addr=192.168.1.20:9001&token=<32 hex characters>
```

| Field | Meaning |
| :--- | :--- |
| `addr` | `ip:port` of the invite listener |
| `token` | 16 random bytes (`token_len = 16`, from `io.randomSecure`) |

The code never contains the swarm key. `Code.parse` and `Code.format`
convert between the text and `{ addr, token }`.

### 1.2 The invite PSK

Both sides turn the token into a Noise pre-shared key:

```zig
pub fn derivePsk(token: [16]u8) [32]u8 // SHA-256("nomadfs-invite-v1:" ‖ token)
```

The invite channel is an ordinary `Noise_XXpsk3` connection
([Chapter 1.1](../net/transport/noise.md)) whose `psk` is this value instead
of the swarm key. Only a holder of the token can finish the handshake. A
128-bit random token cannot be guessed offline, which is why there is no PAKE
(a short PIN would need one).

### 1.3 The inviting side: `Host`

`Host.start(allocator, offer, port, lifetime_s, now)`:

- creates its own `ConnectionManager` with a **throwaway** X25519 key
  (`KeyPair.generate()`), listening on `port` with storage, UPnP and mDNS
  off;
- both callers pass `config.network.port +% 1`: the CLI in
  `inviteCommand` (`src/main.zig`) and the app in `inviteCreate`
  (`nomadfs-gui/src/commands.zig`);
- lifetime is `default_lifetime_s = 10 * 60`; `status(now)` turns
  `waiting` into `expired` after that and stops the listener;
- `code(ip, buf)` formats the code. The CLI uses `--address <ip>` or
  `lanAddress()` (the source address the kernel would use for an outbound
  UDP socket; Linux only), falling back to `127.0.0.1`.

The `Offer` it serves holds the swarm key, the inviter's node port and the
inviter's own pairing ticket (`nomadfs://pair?...`) naming its LAN address
and node port.

`destroy()` stops the listener and zeroes the token, PSK and swarm key
(`std.crypto.secureZero`).

### 1.4 The wire exchange

After the handshake, on one Yamux stream with a 15 s timeout
(`io_timeout_ms`):

```
joiner  -> inviter : [u16 BE len][joiner's ticket URI]
inviter -> joiner  : [32 B swarm key][u16 BE node port][u16 BE len][inviter's ticket URI]
```

Tickets on this wire are bounded by `max_ticket_len = 2048`. The first
connection that delivers a ticket while the state is `waiting` flips it to
`joined`; any later one gets `error.InviteUsed`. One invite, one join.

### 1.5 The joining side: `join`

`join(allocator, code_text, my_ticket_uri) -> Joined` dials `addr` with its
own throwaway key and the derived PSK, sends its ticket and reads back
`{ swarm_key, node_port, ticket_uri, host_ip }`. A wrong, used or expired
token surfaces as `error.InviteRejected`.

Joining is done from the app (`inviteAccept` in
`nomadfs-gui/src/commands.zig`); the CLI can only create invites. After a
successful join the app:

1. writes `swarm_key = "<hex>"` into `nomadfs.conf`;
2. adds `tcp://<host_ip>:<node_port>` to `bootstrap_peers`;
3. trusts the inviter's ticket (trust store upsert, transport key pinned);
4. restarts the node if it was running.

On the inviting side, the CLI (`inviteCommand`) trusts the joiner's ticket
once the state is `joined`; the app does the same when it next polls
`invite_status`. Both devices now hold each other as trusted, with pinned
transport keys.

### 1.6 Security properties

| Property | Why |
| :--- | :--- |
| Code read off the screen later is useless | One join per invite, 10-minute expiry, listener stopped afterwards |
| Swarm key never displayed | It travels only inside the PSK-keyed Noise channel |
| Joiner can't be impersonated afterwards | Its ticket (with transport key) is pinned in the inviter's trust store |
| Throwaway keys | The invite session does not reveal either device's real transport key |

The handshake on the invite listener has no device authenticator
configured, so `NoiseStream.handshake` uses an in-memory Ed25519 identity for
the hello; device identity for this exchange comes from the signed tickets,
not from the session.

---

## 2. Swarm Key Rotation

### 2.1 The signed message (`src/device/rotation.zig`)

```
signed = "nomadfs-rotate-v1:" ‖ epoch (u64 BE) ‖ new_key (32 B)
```

The `ROTATE_KEY` RPC (`src/net/discovery/rpc.zig`, message type 20) carries
`{ epoch, new_key, signer_key, signature }` over an existing, encrypted
connection. The reply is `STORE_ACK { stored }`.

### 2.2 Sending: `Node.rotateSwarmKey`

`Node.rotateSwarmKey(allocator, new_key, epoch) ![]Delivery` in
`src/root.zig`:

1. For every peer in the routing table, connect and read the verified
   device ID of the connection (`getRemoteDeviceID`).
2. If that device is not trusted in the local store: report `not_paired`
   and skip it.
3. Otherwise send `ROTATE_KEY` (`DiscoveryNode.sendRotation`) and report
   `delivered` (accepted), `refused` (the peer said no) or `failed` (error).
4. Every trusted device that was not reached is reported `offline`.
5. Set the node's own `swarm_epoch` to `epoch`.

Only the app triggers rotation (`swarm_rotate_key` in
`nomadfs-gui/src/commands.zig`): it picks a random 32-byte key, uses
`swarm_epoch + 1` from the config, calls `rotateSwarmKey`, writes
`swarm_key` and `swarm_epoch` to `nomadfs.conf`, and restarts the node.
There is no CLI flag for it.

### 2.3 Receiving: acceptance rules

`DiscoveryNode.handleRotateKey` calls `rotation.verify`, which refuses
unless all hold:

| Check | Error |
| :--- | :--- |
| The signer's device ID is trusted in the local store | `UntrustedSigner` |
| The signer is the device authenticated on *this* connection | `SignerNotPeer` |
| The Ed25519 signature verifies | `BadSignature` |
| `epoch` is greater than the receiver's `swarm_epoch` | `StaleEpoch` |

The second rule stops a trusted device's rotation from being relayed by
someone else; the fourth stops replays of an old rotation.

A node also needs a **rotation sink** to adopt the key. Only the app sets one
(`discovery_node.rotation_sink` in `nomadfs-gui/src/commands.zig`); its
handler writes `swarm_key` and `swarm_epoch` to the config and restarts the
node. A node started from the CLI has no sink and answers
`stored = false`, so it keeps its key.

### 2.4 What rotation achieves

Devices that knew the old key but were never paired do not get the new one.
That is the point: after a leak, rotation leaves the thief (and any
unpaired device) on the old key. Offline paired devices must be re-invited
or given the key by hand.

---

## 3. Revocation

The full mechanism is in [Chapter 6.2, "Revocation Propagation"](./pairing.md#revocation-propagation). Summary:

| Piece | Where | Detail |
| :--- | :--- | :--- |
| Command | `nomadfs --revoke <id or fingerprint>` | Removes the entry and records a tombstone; local only |
| Tombstone | `trust.store`, `@`-prefixed lines | `device_id`, `signer_id`, `at`; at most `max_revocations = 256` (`TrustStoreFull` beyond) |
| Signed payload | `trust.revocationMessage` | `"nomadfs-revoke-v1"` ‖ revoked device ID ‖ signer device ID, Ed25519 |
| RPC | `REVOKE` (type 15) → `STORE_ACK` | `{ device_id, signer_key, at, signature }`; `at` is informational, not signed |
| Accept rule | `trust.applyRevocation` | Signature valid, signer ≠ revoked, signer trusted locally |
| Push on dial | `DiscoveryNode.ping` → `pushRevocations` | After a verified PONG on a connection this node opened |
| Sweep | `src/root.zig`, every 60 s | `sweepRevocations(4)`: the 4 peers closest to this node's ID |
| Undo | `--trust` a fresh ticket | Re-pairing clears the tombstone (`clearRevocation`) |

A node that accepts a revocation saves the store at once, so a restart
does not replay it, and later pushes it under its own signature.

---

**Next:** [Chapter 7: The App](../app/gui.md) ·
[Back to the Internals Book](../README.md)
