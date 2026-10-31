# Chapter 5.5: The WebDAV Mount (`src/webdav.zig`, `src/webdav_mount.zig`)

macOS and Windows have no FUSE, but both mount WebDAV with no driver: Finder's **Connect to
Server** (`mount_webdav`) and Explorer's **Map network drive** (`net use`, through the WebClient
service). So on those systems the node serves what the [FUSE mount](./fuse.md) shows over WebDAV
on 127.0.0.1, and the system mounts that:

```
http://127.0.0.1:<port>/<token>/
├── <device>/<share>/…   read-only
└── Swarm/…              read and write
```

`nomadfs --mount <folder or drive>` and the app's **Mount** tab start it on macOS and Windows;
`nomadfs --webdav <port>` serves without mounting (any system, Linux included). All go through
one service, `Node.startWebDav(allocator, port, target)` in `src/node.zig`.

The server sits in the node layer, not in `src/fs/`: it is a front end to the folders (like the
CLI) and speaks to the network, which `fs/` must not.

## 1. Files

| File | Role |
| :--- | :--- |
| `src/webdav.zig` | `Server`: the accept loop, the namespace (`resolve`, `children`), the methods, desktop metadata. |
| `src/webdav/http.zig` | HTTP/1.1: `Request` (head, headers, paths), `Conn` (sized and chunked bodies, responses), `parseRange`, `localHost`. |
| `src/webdav/xml.zig` | What the server writes: hrefs, XML escaping, `httpDate`, content types. |
| `src/webdav/peer.zig` | `sameUser`: whether a loopback connection comes from this user's process (Linux, macOS). |
| `src/webdav_mount.zig` | `Mount`: a running server, mounted or not (`attach`, `detach`, `stop`); `mount_webdav`, `net use`, `umount`. |
| `src/fs/devices.zig` | `Directory`: the devices shown and their names, shared with the FUSE mount. |

`std.http.Server` accepts only the standard methods, not PROPFIND, MKCOL, MOVE, COPY, LOCK or
PROPPATCH, so `http.zig` has its own small HTTP/1.1 layer: keep-alive, `Content-Length` and chunked
bodies, `Expect: 100-continue`, ranges.

## 2. The namespace

`Server.resolve(segments)` turns a path into a `Node`:

- `[]`: the root (the swarm folder, then every online device);
- `["Swarm", …]`: the swarm folder. `SwarmFolder.fileInfo` answers files; a folder is found in
  its parent's `list` (folders can be implied by what is inside them);
- `[device, share, …]`: walks the share's tree with `tree.listDir` through the device's `Remote`.

`children(node)` lists a folder for PROPFIND `Depth: 1`. Files are read with
`SwarmFolder.readAt` or `remote.readShareAt` (with the read-ahead), 256 KiB at a time, so GET with
`Range` streams video like the FUSE mount does.

## 3. Writes

Only `/Swarm/<path>` is writable (`swarmPath`); anything else answers 403.

| Method | Swarm folder call |
| :--- | :--- |
| PUT | the body into a staging file (`stage`), then `addFileAt`, which replaces a file in place |
| MKCOL | `makeDir` |
| DELETE | `remove` (a folder with everything in it) |
| MOVE | `move` (`replace` when `Overwrite: T`) |
| COPY | the source's bytes (from the swarm or a share) staged, then `addFileAt` |

So writes spread like any other edit of the swarm folder. Two rules keep the folder sound:

- a file never replaces a folder: PUT on a folder answers 405, and `addFileAt` itself refuses
  with `error.IsDirectory` (checked before the bytes are stored, and again under the lock);
- COPY stages the bytes first. The destination is touched only once the whole file is read (a
  short read fails), so a device going away mid-copy leaves it as it was.

LOCK answers a token without locking and PROPPATCH reports every property as set: clients mount
read-only without them, and the swarm folder's own merge settles concurrent edits.

## 4. Desktop metadata

Finder writes `._name` and `.DS_Store`, Explorer `Thumbs.db` and `desktop.ini`, next to
everything. Those (`isScratchName`) stay in an in-memory map and never reach the swarm. The map is
bounded (`max_scratch_files` = 4096, `max_scratch_bytes` = 16 MiB, 1 MiB each): past that, other
entries are dropped, which loses only Finder's or Explorer's metadata. A folder deleted or moved
takes its entries with it (`scratchDeleteUnder`), and MOVE or COPY between a metadata name and a
normal one is refused, so a file can't leave the swarm by being renamed `._x`.

## 5. Who may connect

127.0.0.1 is reachable by every program and every account on the computer, so:

1. **The token.** Each `start` picks 16 random bytes (`randomSecure`) and serves only under
   `/<hex>/`; without it, only OPTIONS answers (401 otherwise). `underRoot` compares in constant
   time.
2. **The Host header** must be `127.0.0.1`, `localhost` or `[::1]` (`localHost`): a web page that
   rebinds its own name to 127.0.0.1 can't reach the server. A page can't read responses either:
   no CORS headers are sent.
3. **This user only** (`peer.zig`). macOS shows every mount's URL to every account: the mount
   table and the `webdavfs_agent` command line both have it. So on Linux and macOS each
   connection is checked before its first request:
   - Linux: `/proc/net/tcp` (and `tcp6`) list each socket's owner; the client's socket is the one
     whose local port is the connection's remote port and whose remote end is the server.
   - macOS: libproc (`proc_listpids` for this user, `proc_pidinfo` for each one's descriptors,
     `proc_pidfdinfo` for a socket's ports). macOS lets a process read only its own user's
     descriptors, so another account's client is never found and its connection is closed
     unanswered. The `socket_fdinfo` offsets come from Zig's macOS headers
     (`zig translate-c`) and are the same on arm64 and x86_64.

   Windows mounts through the WebClient service, which runs as another account, and a drive
   mapping is private to its user: the token is the check there.

`max_connections` (64) caps the connections served at once, and an idle one times out after 60 s.

## 6. Mounting (`webdav_mount.zig`)

- **macOS**: creates the folder, then `/sbin/mount_webdav -S -v NomadFS <url> <folder>` (`-S`: no
  dialogs). Unmounting is `umount`, then `umount -f` if Finder still holds the volume, or forced
  at once when the server has already stopped. The app's signal handler calls `forceUnmount`
  (the `unmount(2)` system call alone, safe in a handler) so no dead volume stays behind.
- **Windows**: `net use <letter or *> <url> /persistent:no`; with `*`, the drive letter is read
  from the output. Unmounting is `net use <letter> /delete /y`. The CLI's console handler waits
  for it when the window closes.

Commands run through their own `std.Io.Threaded` with an allocator and the process environment:
the global single-threaded `Io` has neither, and spawning needs both on macOS.

WebClient refuses files over 50 MB by default (`FileSizeLimitInBytes` in
`HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`); the user docs say how to raise it.

## 7. Stopping

`Server.stop` closes the listener, joins the accept loop, shuts every connection down and waits
for them, then stops the device refresher (a request still running may list the devices).
`Mount.stop` unmounts first, so the system can finish writing, then stops and frees the server.

## 8. Tests

- `tests/cluster/webdav_test.zig`: a node with a swarm folder and the server, over real
  connections:
  - the token, 401 without it, the Host check;
  - PUT (sized, chunked, `100-continue`), MKCOL, GET with ranges, MOVE, COPY over a file, DELETE;
  - PUT on a folder (405), crossing metadata renames (403);
  - a chunked body arriving after its head (headers still read), metadata dropped with its folder.
- Unit tests: `parseRange`, `splitPath`, `localHost`, `httpDate`, `tableOwner` (`/proc/net/tcp`
  parsing), and the metadata caps.
- `scripts/webdav-smoke.sh`:
  - `serve`: curl against `--webdav` on Linux and Windows, plus another user refused (Linux,
    `sudo -u nobody`);
  - `mount`: macOS mounts with `mount_webdav`, then copies, renames and deletes through it, and
    another user who reads the URL from the mount table is refused.

  The desktop workflow runs both.
