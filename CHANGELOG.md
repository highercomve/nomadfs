# Changelog

All notable changes to NomadFS. Versions follow [Semantic Versioning](https://semver.org/);
before 1.0, a minor version may break compatibility.

## 0.2.1 - 2026-10-28

### Fixed

- The one-time move of old blocks into the read cache waits for every share's first scan to
  finish, however long it takes, instead of giving up after 30 minutes. A large share still
  hashing could otherwise have had some of its own blocks moved into the cache.

## 0.2.0 - 2026-10-28

### Added

- **Read cache.** Files opened from other devices are kept in a read cache, so they open again
  without the network, and the least recently read blocks make room when it is full. It holds
  2 GB by default: `cache_mb` under `[storage]` (`0` = no limit), or the limit setting in the app.
  What a device writes, backs up or receives as a replica is kept apart and never evicted.
- **See and clear it:** **About → Read cache** in the app shows its size, with **Clear cache**;
  on the command line, `nomadfs --cache` and `nomadfs --clear-cache`.
- On first start, 0.2.0 moves the blocks it fetched before into the read cache, once, keeping
  the device's own shares and swarm folder files.

### Changed

- `quota_mb` now applies only to the blocks a device keeps; the read cache has its own limit.

## 0.1.1 - 2026-10-28

### Fixed

- **Android:** a fresh install couldn't start its node or join a swarm. The device identity
  was saved in a way Android doesn't allow apps, and a failed network accept crashed the app.
  The desktop app and the command line for ARM had the same accept bug.
- Invite and pairing codes typed on a phone are accepted when the keyboard capitalizes the
  first letter.

## 0.1.0 - 2026-10-28

A fresh start. This release breaks compatibility with every earlier build,
which were all withdrawn: **update every device and join them again**.

### Breaking

- **Handshake v2.** Connections use the standard `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`,
  with the prologue and the ephemeral keys mixed in as the Noise spec requires, and
  checked against the published Cacophony test vector. Earlier builds can't connect.
- **New trust store (`NMDFSTR2`).** The first start of 0.1.0 moves an old trust store to
  `trust.store.v1.bak` and starts empty: pair or invite your devices again.
- **Signed revocation time.** Revocations sign when they were made (`nomadfs-revoke-v2`),
  so re-pairing a removed device is no longer undone by an older revocation.
- **UPnP is off by default**, for the command line too (`upnp_enabled = true` turns it on).
- **On Android**, uninstall the earlier app before installing 0.1.0: its version number is
  lower, so Android won't install it over the old one.

### Added

- **Notes in the swarm folder.** Text drop stores each note as a `.txt` file in the swarm's
  `Notes` folder, so every device lists every note; earlier notes move there on their own.
- **Storage quota.** `quota_mb` under `[storage]` caps the space blocks from other devices
  can take (0, the default, is unlimited).
- **Device names you can trust.** Paired devices are named after their pairing label in the
  app and the mount; unpaired devices always show a device-ID suffix and a "Not paired" badge,
  so another device can't pass itself off by copying a nickname.

### Security

- Invites: the joining device must prove it holds the identity in its ticket, the inviter
  checks expiry itself, and an older ticket can't replace a newer one.
- Revoked devices are refused under every policy, and their open connections are closed.
- Limits on what unauthenticated and authenticated peers can make a device spend:
  handshakes in flight (with a total deadline), connections, request threads, memory per
  request, block sizes, and the DAG a read may walk.
- The DHT keeps only addresses learned first-hand and drops unusable ones (loopback from
  others, port 0, multicast, link-local).
- UPnP, when on, uses a one-hour lease renewed while running and removed on stop, and only
  trusts a router on the local network.
- The app writes its configuration atomically and private (`0600`, directory `0700`).

### Fixed

- Crashes: truncating a swarm folder file after closing it; a peer sending a huge file
  size or version clock; a second invite join (double free).
- Shutdown: no use of freed memory while requests finish, no hang while discovery dials.
- The mount serves several requests at once, so one slow device no longer freezes it, and
  frees what the kernel forgets; long sessions no longer grow without bound.
- A swarm folder too large to load is moved aside instead of overwritten, and deletions are
  forgotten after 90 days. A device offline for longer may bring a deleted file back.
- Many smaller leaks and races in the trust store, the mobile library, the app and the
  storage engine.
