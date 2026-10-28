# Chapter 8.1: Installation & Running

User guide: [Getting started](https://nomadfs.foreachdeveloper.com/docs/getting-started/).
This chapter is the operator's view: what the binary does, flag by flag, and
how to keep a node running.

## 1. Getting the Binary

Releases on GitHub carry the app (Android APK; Linux AppImage, deb, rpm) and
the `nomadfs` command line for Linux. `scripts/install.sh` installs the latest
one for the current user (AppImage and CLI in `~/.local/bin`, launcher entry
and icons), checking each file against the release's `SHA256SUMS`;
`scripts/install-local.sh` does the same from a build of the checkout.

From source, with [Zig 0.16.0](https://ziglang.org/download/):

```sh
git clone https://github.com/highercomve/nomadfs.git
cd nomadfs
zig build -Doptimize=ReleaseSafe     # zig-out/bin/nomadfs, zig-out/lib/libnomadfs.so
zig build lib                        # only the C ABI library (mobile bindings)
```

`make <target>` (`x86_64-linux`, `aarch64-linux`, `x86_64-macos`,
`aarch64-macos`, `x86_64-windows`) cross-compiles into `build/<target>/`.

The [`Dockerfile`](../../Dockerfile) builds through that Makefile into an
Alpine image (`ENTRYPOINT ["nomadfs"]`, `EXPOSE 9000`, `/etc/nomadfs`,
`/var/lib/nomadfs`). **It still downloads Zig 0.15.2**, which no longer
builds this tree; update it before relying on it. No image is published.

The Linux mount additionally needs `fusermount3` (package `fuse3`).

**Making a release.** Bump the version in `build.zig.zon`, `nomadfs-gui/build.zig.zon` and
`nomadfs-gui/build.zig`, then `scripts/release.sh [out-dir]` builds every asset (both CLIs, the
AppImage, deb, rpm and the APK), signs the update manifest the apps check (`latest.json`: the
AppImage for `x86_64-linux`, the APK for `aarch64-android` and `x86_64-android`) and writes
`SHA256SUMS`. It signs with `NOMADFS_UPDATE_KEY` (default
`~/.config/oriel/keys/nomadfs-update.key`); the apps only accept manifests signed with it, so keep
a backup of that file and never commit it. Upload everything, `latest.json` included, to the
GitHub release: the apps read `releases/latest/download/latest.json`.

## 2. The Command Line (`src/main.zig`)

There are no subcommands. The binary takes at most one command flag, plus
options and an optional config path:

```
nomadfs [options] [config_path]
```

| Flag | What it does |
| :--- | :--- |
| *(none)* | Run the node: listen, bootstrap, share, sync the swarm folder, until killed |
| `--mount <dir>` | Run the node **and** mount `<dir>` (Linux; needs storage enabled). Unmounts on Ctrl-C or `SIGTERM` |
| `--invite` | Print a one-time invite (QR + code) and wait up to 10 min for one device to join; then trust it |
| `--pair` | Print this device's signed pairing ticket (24 h) and QR code |
| `--trust <uri>` | Verify a `nomadfs://pair?...` ticket and add it to `trust.store` |
| `--devices` | List trusted devices |
| `--revoke <id>` | Remove a trusted device by device ID or fingerprint, recording a signed tombstone |

| Option | Applies to | Meaning |
| :--- | :--- | :--- |
| `--config <path>` | all | Config file (same as the positional path; giving both is an error) |
| `--share Name:/path` | node, mount | Add a shared folder (repeatable) |
| `--swarm-backup` | node, mount | Keep a copy of every swarm folder file here |
| `--address <addr>` | `--pair`, `--invite` | Address to publish: `host:port[,host:port…]` for `--pair`, an IP for `--invite` |
| `--help`, `-h` | | Usage |

Unknown flags exit with an error. `--pair`, `--trust`, `--devices` and
`--revoke` only touch local files (`device.key`, `node.key`, `trust.store`);
they don't start a node. Without `--address`, `--pair` publishes
`127.0.0.1:<port>`, which only works on the same host, and `--invite` uses
the LAN address the kernel would route through.

Joining with an invite code is done in the app; the CLI can create invites
but not accept them. Two CLI-only machines are connected by giving both the
same `swarm_key` and each other's address in `bootstrap_peers`.

## 3. What Starts When the Node Runs

`Node.init` (`src/root.zig`) in order:

1. `ConnectionManager` with the transport key (`node.key`, created on first
   run, mode `0600`), and its reaper thread.
2. `StorageEngine` at `storage_path`, if `enabled`.
3. The DHT node; with storage, the `ShareIndex` (registers each `share`,
   rescans every 30 s) and the `SwarmFolder` (sync every 10 s, plus the
   backup loop if `swarm_backup`).
4. `BlockManager`, the (unused) hash ring, the device identity
   (`device.key`) and trust store, and the device authenticator.

`Node.bootstrap` dials each `bootstrap_peers` entry (5 attempts, 1 s apart),
PINGs it and sends `DIAL_BACK`; then it looks up its own ID once and every
60 s refreshes buckets and sweeps revocations. `Node.run` opens the listener,
starts LAN announcements and UPnP if enabled, and loops until the `running`
flag clears.

## 4. Running as a Service

```ini
# /etc/systemd/system/nomadfs.service
[Unit]
Description=NomadFS node
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/nomadfs /etc/nomadfs/nomadfs.conf
WorkingDirectory=/var/lib/nomadfs
Restart=on-failure
User=nomadfs

[Install]
WantedBy=multi-user.target
```

Set `key_path` (e.g. `/var/lib/nomadfs/keys/node.key`) so the keys and trust
store land in a known place rather than `~nomadfs/.nomadfs`. An always-on
machine is the natural place for `swarm_backup = true`.

## 5. Nodes Without Storage

`enabled = false` gives a node that joins the DHT and answers RPCs but has
no block store: no shares, no swarm folder, no mount, and
`BlockManager.put`/`get` (and the C ABI's `nomadfs_put_file`/`get_file`)
fail with `StorageDisabled`. It is mainly useful as a DHT/bootstrap
contact.

## 6. Troubleshooting

- **Output**: everything goes to stderr (see [Chapter 8.3](./observability.md)).
  `Noise Handshake FAILED` with a decrypt error at message 3 means the two
  devices have different swarm keys.
- **Reachability**: the TCP `port` (default 9000; 14700 in the app's
  generated config) must be reachable; invites use `port + 1`.
- **LAN discovery**: UDP 5354 multicast to 224.0.0.251 must be allowed; the
  app's own config turns it off.
- **Mount**: `FusermountNotFound` means `fuse3` is missing.

---

**Next:** [Chapter 8.2: Configuration Reference](./configuration.md) ·
[Back to the Internals Book](../README.md)
