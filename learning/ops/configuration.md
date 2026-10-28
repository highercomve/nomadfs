# Chapter 8.2: Configuration Reference

Every NomadFS process (the CLI node, the app, the mobile library) reads one
`nomadfs.conf`, parsed by `parseConfigText` in `src/config.zig`. User guide:
[Getting started](https://nomadfs.foreachdeveloper.com/docs/getting-started/#config).

## 1. Where the File Is Found

A path given on the command line (positional argument or `--config`) is used
as is. Otherwise `findAndParseConfig` tries, in order:

1. `./nomadfs.conf` (current directory)
2. `~/.nomadfs/nomadfs.conf` (`$HOME`, or `%USERPROFILE%` on Windows)
3. `/etc/nomadfs/nomadfs.conf`
4. `/usr/share/nomadfs/nomadfs.conf`

A file that exists but fails to parse is skipped like a missing one; the error
of the last location is the one reported. A path starting with `~` is
expanded. The file is read into a 16 KiB buffer, so larger files are cut off.

## 2. Syntax

```ini
[node]
nickname = "Laptop"
swarm_key = "0123…cdef"          # 64 hex characters

[storage]
storage_path = "/home/me/.nomadfs/data"

[network]
port = 9000
bootstrap_peers = ["tcp://192.168.1.20:9000"]

share = "Documents:/home/me/Documents"
share = "Photos:/home/me/Pictures"
```

The format looks like TOML but the parser is much simpler:

- one `key = value` per line; blank lines and lines starting with `#` are
  skipped;
- **`[section]` headers are ignored**: keys are global, so the sections above
  are only for readability;
- surrounding double quotes are stripped from values; there are no escapes,
  and a value is cut at a second `=` (the line is split on `=`);
- **unknown keys are ignored silently**, so a typo leaves the default in
  place;
- a repeated key overwrites the earlier value, except `share` (one per line,
  replaced by name) and `bootstrap_peers` (lists are concatenated).

## 3. Keys

### Identity and swarm

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `nickname` | string | **required** | Name other devices show for this one; also the author name in the swarm folder. |
| `swarm_key` | string | **required** | 32-byte swarm key: 64 hex characters, or a raw 32-byte string. Anything else is `InvalidSwarmKey`. Generate with `openssl rand -hex 32` or `make gen-swarm-key`. |
| `swarm_epoch` | u64 | `0` | Generation of the swarm key; rotations with an epoch not above it are refused ([Chapter 6.3](../security/invites.md#2-swarm-key-rotation)). Written by the app when it rotates or adopts a key. |
| `key_path` | path | unset | File of the X25519 transport key (`node.key`). When set, `device.key` and `trust.store` live in the same directory. When unset, the directory is `.` if `./device.key` exists, otherwise `~/.nomadfs` (`src/device/paths.zig`). |

### Storage

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `storage_path` | path | **required** | Block store directory (one file per block). The swarm manifest is `<storage_path>.swarm.json`, the backup record `<storage_path>.swarm.json.backup`, the FUSE staging dir `<storage_path>.swarm.json.staging/`. |
| `enabled` | bool | `true` | Without storage there are no shares, no swarm folder, no mount (`--mount` refuses) and `BlockManager.put`/`get` fail with `StorageDisabled`. The node still joins the DHT and answers RPCs. |
| `replicas` | u8, ≤ 20 | `0` | Peers closest to a new file's root CID that `BlockManager.put` pushes the whole DAG to (`PUT_BLOCK`). Above 20 is `ReplicasOutOfRange`. Shares and the swarm folder don't use `put`. |
| `write_quorum` | u8 | `1` | Provider-record acknowledgements (`ADD_PROVIDER`) `BlockManager.put` needs. `0` skips the announcement, so a device with no peers can store. With `1` and no peers, `put` returns `QuorumNotReached` (blocks stay local). |
| `swarm_backup` | bool | `false` | Copy every swarm folder file into this device's store ([The Swarm Folder](../fs/swarm.md)). Same as `--swarm-backup`. |
| `share` | `"Name:/path"` | none | A shared folder; repeatable. Split at the first `:`. Same as `--share`. |

### Network

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `port` | u16 | `9000` | TCP listen port. `0` is rejected. Invites listen on `port + 1`. |
| `transport` | string | `"tcp"` | Only `tcp` works; `quic` is `UnsupportedTransport`, anything else `InvalidTransport`. |
| `bootstrap_peers` | list | `[]` | `["tcp://host:port", …]`; the `tcp://` prefix is optional. Dialled at start, 5 attempts each. The app appends the inviter's address here after a join. |
| `upnp_enabled` | bool | `true` | Ask the router (UPnP IGD) to forward `port`; the mapping is removed on stop. |
| `enable_mdns` | bool | `true` | LAN announcements (`NMFS{…}` on 224.0.0.251:5354 every 2 s), see [Local Discovery](../net/transport/mdns.md). |

### Security

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `require_trusted_devices` | bool | `false` | Refuse handshakes from devices not in `trust.store` (`UntrustedDevice`). |

Booleans are `true` only when the value is exactly `true`.

## 4. The App's Default File

The desktop and Android app create their own config on first start
(`nomadfs-gui/src/commands.zig`) with a random swarm key, `key_path` inside
the app's data directory, `port = 14700`, `upnp_enabled = false`,
`enable_mdns = false`, `write_quorum = 0` and `replicas = 1`. It then edits
that file line by line (nickname, shares, swarm key after a join or
rotation, bootstrap peers), keeping comments and other settings.

## 5. Keys That Don't Exist

Older versions of this book listed `listening_address`, `enable_autonat` and
`[debug] log_level`. None of them is read: the node always listens on `0.0.0.0` (IPv4),
DIAL_BACK runs whenever a bootstrap peer connects, and there are no log
levels ([Chapter 8.3](./observability.md)).

---

**Next:** [Chapter 8.3: Observability](./observability.md) ·
[Back to the Internals Book](../README.md)
