# NomadFS: Strategic Pivot & Technical Roadmap

## 🎯 Executive Summary & Strategic Pivot

NomadFS is pivoting from an academic, fully-distributed peer-to-peer storage cluster (Kademlia DHT, global consistent hash ring, multi-node quorum for all data) to a **pragmatic, user-centric Personal Device Mesh and Modular Interconnect Platform for Roaming Devices**.

### The Core Problem with the Original Architecture
- **Premature Complexity:** Full DHTs and global consistent hash rings impose enormous overhead, synchronization debt, and network thrashing on mobile and roaming devices.
- **Distributing Everything is the Wrong Default:** Users do not want or need their entire phone storage or desktop drive replicated everywhere. Phone storage is constrained, battery is finite, and transferring gigabytes over cellular is unacceptable.
- **Monolithic Thinking:** A roaming device mesh isn't just about disk blocks; it is the ultimate substrate to share files, synchronize clipboards, stream phone cameras to desktops as virtual webcams, and mirror notifications.

### The New Architecture: Personal Device Mesh & Capability Platform
1. **Base Kernel (Zig 0.16):** Lightweight, robust content-addressed engine, authenticated Noise transport, and Yamux stream multiplexer.
2. **Native Persistent Transport (No WebSockets Needed):** All nodes (desktop, mobile via Oriel, and headless servers) are native Zig binaries with full OS socket access. We use **native persistent TCP + Noise + Yamux** directly, eliminating HTTP/WebSocket framing overhead, masking, and extra dependencies.
3. **Modular Capability Substrate (`NomadModule`):** Pluggable module system where independent capability streams (Filesystem, Clipboard, Camera, Notifications) run multiplexed over a single authenticated tunnel without head-of-line blocking.
4. **First-Class Apps via Oriel:** Cross-platform GUI for Linux, Windows, macOS, Android, and iOS using [Oriel](../oriel) (Zig + system webview / native compiled views).
5. **Headless Server & Backup Node ("The Vault & Relay"):** Lightweight headless daemon/Docker container for home servers, Raspberry Pi, NAS, or VPS that acts as a dedicated backup repository and always-on roaming relay.
6. **Directed Sync & Backup Policies:** Selective, one-way or two-way sync rules (e.g. automatically back up phone photos **only** to the home server, without filling desktop storage).
7. **Frictionless Device Pairing (Penny Goblin Pattern):** Cryptographic identity exchange via QR codes and one-time links (`nomadfs://pair`), revocable device trust, and mutual TLS/Noise authentication.
8. **On-Demand Device Mounting:** Mount remote device folders on-demand (e.g., mount your Android phone's camera roll or documents directly into Linux via FUSE or virtual filesystem) without full replication.
9. **Persistent Roaming & NAT Keep-Alive:** Yamux heartbeat `PING` frames maintain NAT state table mappings alive indefinitely across cellular and external networks, with the server node acting as a zero-knowledge raw TCP relay when direct peer connection isn't possible.

---

## ⚡ Why Native Persistent TCP Beats WebSockets

Since NomadFS clients run natively on all platforms (using Zig on Linux/macOS/Windows and Oriel native runtimes on Android/iOS), **we are not constrained by web browser sandboxes**. 

| Dimension | WebSockets | Native TCP + Noise + Yamux (NomadFS) |
|---|---|---|
| **Framing Overhead** | HTTP upgrade handshake, 2–10 byte frame headers, 4-byte client masking | Zero HTTP overhead; clean 12-byte binary Yamux multiplexer header |
| **Dependencies** | Requires HTTP parser, WebSocket server/client libraries | Pure Zig standard library (`std.net.Stream`) + in-tree Noise crypto |
| **Throughput & Latency** | Masking/unmasking bytes on mobile CPUs wastes cycles | Zero-copy kernel buffer streaming directly to crypto cipher |
| **Multiplexing** | Single logical channel (requires custom sub-protocol) | Yamux native multiplexing (thousands of independent streams) |
| **Keep-Alive & NAT** | Application ping/pong | Native Yamux `PING` frames maintain stateful NAT bindings |
| **Relay Efficiency** | Relay must decode WS frames | Zero-knowledge raw TCP pipe splicing (e.g. `splice`/`sendfile`) |

---

## 🖥️ Node Roles in the Personal Mesh

NomadFS nodes are symmetric at the protocol level, but operate under three pragmatic user roles:

```
                  ┌───────────────────────────────┐
                  │      HOME SERVER / VPS        │
                  │   Headless Daemon & Docker    │
                  │   • Always-On Backup Vault    │
                  │   • Native TCP Roaming Relay  │
                  │   • Zero GUI (CLI / systemd)  │
                  └───────────────▲───────────────┘
                                  │
                 Directed Backup  │  Persistent TCP/Yamux
                 (Phone Photos)   │  & On-Demand Mount
                                  │
         ┌────────────────────────┴────────────────────────┐
         │                                                 │
 ┌───────▼──────────────────────┐          ┌───────────────▼──────────────┐
 │       ANDROID / iOS          │          │      LINUX / MAC / WIN       │
 │       Mobile Node            │◄────────►│      Desktop Node            │
 │ • Camera & Photo Exporter    │ Direct   │ • FUSE Mount (/mnt/phone)    │
 │ • On-Demand Streamer         │ LAN P2P  │ • Virtual Webcam Receiver    │
 │ • Auto-backup on Wi-Fi       │ (mDNS)   │ • Clipboard & Notify Sync    │
 └──────────────────────────────┘          └──────────────────────────────┘
```

1. **Desktop Nodes (Linux, macOS, Windows):**
   - Full GUI via Oriel with system tray and background agent.
   - FUSE filesystem driver for mounting remote devices and browsing on-demand.
   - Virtual webcam receiver (`v4l2loopback`), clipboard synchronization, and notification receiver.

2. **Mobile Nodes (Android, iOS):**
   - Full GUI via Oriel mobile runtime.
   - Storage Access Framework (SAF) document provider integration.
   - Camera frame sender for desktop virtual webcam.
   - Background photo auto-backup scheduler (triggered when connected to Wi-Fi and charging).

3. **Headless Server Node ("The Vault & Relay"):**
   - Minimal resource footprint (~15MB RAM), written in pure Zig.
   - Runs headless via systemd, Docker, or bare metal on home servers, NAS, Raspberry Pi, or cheap VPS.
   - Terminal-based pairing (`nomadfs pair --generate` renders ASCII QR code directly in the terminal).
   - Functions as:
     1. **Targeted Backup Repository:** Stores phone photo backups and historical file versions.
     2. **Always-On Roaming Relay:** When two roaming devices are behind restrictive symmetric NATs and cannot direct-connect, the server splices their raw encrypted Yamux TCP streams with zero knowledge of payload content.

---

## 🔄 Directed Sync Policies & Asymmetric Replication

NomadFS implements **Targeted Sync Policies** instead of indiscriminate global mesh replication:

```
                       ┌─────────────────────────┐
                       │   Phone Camera Roll     │
                       │       (/DCIM)           │
                       └────────────┬────────────┘
                                    │
                                    │ Policy: Backup Only
                                    │ Target: HomeServer
                                    ▼
                       ┌─────────────────────────┐
                       │    Home Server Vault    │
                       │ (/srv/nomad/backups/dcim)│
                       └────────────┬────────────┘
                                    │
                                    │ Policy: On-Demand Mount
                                    │ (Zero local storage)
                                    ▼
                       ┌─────────────────────────┐
                       │      Linux Desktop      │
                       │ (/mnt/nomadfs/server/…) │
                       └─────────────────────────┘
```

### Policy Types:
1. **One-Way Backup (Archival):**
   - *Example:* Phone Photos ➔ Home Server.
   - Changes on phone upload new photos to the server.
   - Phone deletions can be configured to **not** delete on server (tamper-proof archival).
   - Desktop does not download photos automatically, keeping desktop disk clean.
2. **Two-Way Selective Sync (Vault):**
   - *Example:* `Documents/WorkVault` synced symmetrically across Laptop, Desktop, and Server.
   - Offline-first writes with Vector Clock causal tracking.
3. **On-Demand Mount (Virtual View):**
   - Any device can mount the Server's photo vault via FUSE or the in-app explorer to view or stream full-resolution photos without pre-syncing them.
4. **Local Space Reclamation ("Free Up Space"):**
   - Once the phone verifies that photos are cryptographically stored on the Server node (via Merkle CID receipt), the user can tap "Free Up Space" to safely purge local phone copies while leaving virtual thumbnails.

---

## 🧩 The Modular Capability Mesh Architecture

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      Oriel UI & Headless Daemons                       │
 │        Desktop (GUI) · Mobile (GUI) · Server (Headless Daemon)         │
 └──────┬─────────────────┬───────────────────┬───────────────────┬───────┘
        │                 │                   │                   │
 ┌──────▼──────┐   ┌──────▼──────┐     ┌──────▼──────┐     ┌──────▼──────┐
 │  nomad-fs   │   │  clipboard  │     │   camera    │     │   notify    │
 │ FUSE Mount  │   │ Bi-dir Sync │     │ Virtual Cam │     │ Notification│
 │ & Sync DAG  │   │ & History   │     │v4l2loopback │     │ Mirroring   │
 └──────┬──────┘   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
        │                 │                   │                   │
 ┌──────┴─────────────────┴───────────────────┴───────────────────┴───────┐
 │               NomadFS Core Substrate & Module Dispatcher               │
 │  • Protocol Negotiation: /nomad/<module>/<version>                     │
 │  • Directed Sync Engine & Targeted Device Rules                        │
 │  • Pinned Device Registry & Granular Per-Module Permissions Matrix     │
 │  • Yamux Stream Multiplexer (Concurrent non-blocking streams)          │
 │  • Noise XX Authenticated & End-to-End Encrypted Session               │
 └───────────────────────────────────┬────────────────────────────────────┘
                                     │
           ┌─────────────────────────┴────────────────────────┐
           ▼                                                  ▼
    [ Direct LAN P2P ]                             [ Persistent TCP Relay ]
  (mDNS discovery / High-speed Wi-Fi)            (Home Server / VPS NAT Splicer)
```

### Module Interface (`NomadModule`)
```zig
pub const Module = struct {
    id: []const u8, // "fs", "clipboard", "camera", "notify", "input"
    name: []const u8,
    protocol_tag: []const u8, // e.g. "/nomad/camera/1.0"
    version: SemVer,

    init: *const fn(allocator: Allocator, config: ModuleConfig) anyerror!*ModuleContext,
    deinit: *const fn(ctx: *ModuleContext) void,

    handle_inbound_stream: *const fn(ctx: *ModuleContext, peer: *Peer, stream: *YamuxStream) anyerror!void,

    on_peer_paired: *const fn(ctx: *ModuleContext, peer: *Peer) void,
    on_peer_connected: *const fn(ctx: *ModuleContext, peer: *Peer) void,
    on_peer_disconnected: *const fn(ctx: *ModuleContext, peer: *Peer) void,

    get_status_json: *const fn(ctx: *ModuleContext, arena: Allocator) anyerror![]const u8,
    update_permissions: *const fn(ctx: *ModuleContext, peer_id: []const u8, granted: bool) anyerror!void,
};
```

---

## 📦 Pluggable Modules Blueprint

1. **`nomad-camera` (Phone as Linux Webcam):**
   - Phone captures frames via Oriel camera API; streams over `/nomad/camera/1.0`.
   - Linux writes to `v4l2loopback` (`/dev/videoX`). Apps (Zoom, OBS, Discord) see it as a native USB camera.
2. **`nomad-clipboard` (Instant Clipboard Sync):**
   - Oriel clipboard listeners + BLAKE3 hash guard against infinite echo loops.
3. **`nomad-fs` (Mounting & Directed Backup):**
   - Linux FUSE mount (`/mnt/nomadfs/<device>/`).
   - Directed photo backup to Home Server with background Wi-Fi scheduler.
4. **`nomad-notify` (Notification Mirroring):**
   - Mirrors Android notifications to desktop; handles dismiss and quick replies.
5. **`nomad-input` (Remote Control):**
   - Phone as trackpad, presentation clicker, or media remote control.

---

## 🗺️ Revised Roadmap Phases

```
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Base Engine & Wire Hardening (Zig 0.16)                       │
│ • Zig 0.16 Migration  • FastCDC Block Store  • Noise XXpsk3  • Yamux   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│ Phase 2: Device Identity & Pairing (Penny Goblin Pattern)              │
│ • Device Keys (Ed25519)  • GUI QR & Headless CLI ASCII QR Pairing      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│ Phase 3: Core Substrate & Module Dispatcher Architecture               │
│ • NomadModule Interface  • Yamux Stream Negotiation  • Permissions     │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
┌───────────────────▼────────────────┐ ┌─────────────▼───────────────────┐
│ Phase 4: Filesystem & Backup Engine│ │ Phase 5: Media & Utility Modules│
│ • FUSE On-Demand Mount & LRU Cache │ │ • nomad-camera (v4l2loopback)   │
│ • Directed Sync & Phone Backup     │ │ • nomad-clipboard & notify      │
└───────────────────┬────────────────┘ └─────────────┬───────────────────┘
                    │                                │
┌───────────────────▼────────────────────────────────▼───────────────────┐
│ Phase 6: Headless Server Daemon & Oriel Applications                   │
│ • nomadfs-server (Headless Docker/systemd)  • Oriel Desktop & Mobile   │
└───────────────────┬────────────────────────────────────────────────────┘
                    │
┌───────────────────▼────────────────────────────────────────────────────┐
│ Phase 7: Persistent Roaming & NAT Splicing Relay                       │
│ • Server as TCP Stream Relay  • Yamux PING Keep-Alives & NAT Splicing  │
└────────────────────────────────────────────────────────────────────────┘
```
