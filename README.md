<p align="center">
  <img src="assets/brand/nomadfs-banner.svg" alt="NomadFS — Personal device mesh & virtual filesystem for roaming devices" width="100%">
</p>

# NomadFS

NomadFS is a personal device mesh and virtual file system optimized for **Roaming Devices**—laptops, phones, home workstations, and headless servers that frequently change IP addresses, switch between Wi-Fi and cellular, or go offline.

Rather than forcing an all-or-nothing global distributed storage cluster across every device, NomadFS provides:
1. **Frictionless Device Pairing** (QR code / link-based mutual authentication inspired by [Penny Goblin](../penny-goblin)).
2. **On-Demand Remote Mounting** (e.g. mount your Android phone's photo library or documents directly onto your Linux desktop via FUSE without pre-downloading gigabytes).
3. **Directed Asymmetric Sync** (e.g. back up phone photos **only** to an always-on home server vault, without flooding desktop storage).
4. **Native Persistent Transport** (pure TCP + Noise + Yamux stream multiplexing; no HTTP or WebSocket overhead).
5. **Modular Capability Substrate** (pluggable modules for file mounting, bi-directional clipboard sync, phone-as-webcam streaming via `v4l2loopback`, and notifications).
6. **Cross-Platform Applications** built with [Oriel](../oriel) for Linux, Windows, macOS, Android, and iOS, plus a headless CLI daemon for servers and NAS.

> 📖 **Read the full strategic roadmap and architecture plan in [ROADMAP.md](ROADMAP.md)**.

## 🚀 Core Pillars

- **Frictionless Pairing:** Pair devices with a single QR scan or `nomadfs://pair` link using pinned cryptographic identities.
- **On-Demand Device Mounting:** Stream files when you need them. Mount any paired phone or computer folder directly in your desktop OS with local LRU caching.
- **Directed Backup Policies:** Dedicated backup rules (e.g. Phone ➔ Home Server) with background Wi-Fi schedulers and local "Free Up Space" offloading.
- **Pure Native Transport:** Raw persistent TCP sockets with Noise encryption and Yamux stream multiplexing. Built-in Yamux `PING` frames maintain NAT mappings alive across roaming networks.
- **Pluggable Capabilities:** Run filesystems, clipboards, webcam streams, and notifications concurrently over one connection with zero head-of-line blocking.
- **Cross-Platform UI with Oriel:** Unified native/webview application for Linux, Windows, macOS, Android, and iOS, plus a lightweight headless daemon for servers.

## 🛠 Tech Stack

- **Core Engine:** [Zig 0.16](https://ziglang.org/)
- **App Framework:** [Oriel](../oriel) (Zig + system webview / native DOM)
- **Pairing & Identity:** Ed25519 / X25519 pinned identities with revocable trust registry
- **Transport Security:** Noise Protocol Framework (`XXpsk3` / `IK`)
- **Multiplexing:** Yamux streams over native persistent TCP
- **Storage & Hashing:** Merkle DAG with BLAKE3 content addressing
- **Mount Integration:** FUSE on Linux/macOS, Storage Access Framework (SAF) on Android

## 🏗 Architecture Overview

```
 ┌──────────────────────────────────────────────────────────────┐
 │               Oriel GUI App & Headless Server                │
 │     (Desktop · Mobile · Headless Server / NAS Daemon)        │
 └──────────────┬──────────────────────────────┬────────────────┘
                │                              │
 ┌──────────────▼─────────────┐  ┌─────────────▼───────────────┐
 │   On-Demand Mount (FUSE)   │  │   Directed Backup & Sync    │
 │   • Remote phone browsing  │  │   • Phone ➔ Server vault    │
 │   • Real-time streaming    │  │   • Vector Clocks (AP)      │
 │   • Local LRU block cache  │  │   • Merkle DAG delta sync   │
 └──────────────┬─────────────┘  └─────────────┬───────────────┘
                │                              │
 ┌──────────────▼──────────────────────────────▼───────────────┐
 │            NomadFS Core Library (Zig 0.16)                  │
 │   Noise XX Session · Yamux Streams · FastCDC · BLAKE3       │
 └──────────────────────────────┬──────────────────────────────┘
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
   [ Direct LAN P2P ]                     [ Persistent TCP Relay ]
  (mDNS, high-speed Wi-Fi)              (Home Server / VPS Splicer)
```

## 🗺️ Roadmap & Implementation Phases

See [ROADMAP.md](ROADMAP.md) for the detailed step-by-step breakdown across all seven phases:
- **Phase 1:** Base Engine & Wire Hardening (Zig 0.16)
- **Phase 2:** Device Identity & Pairing System (Penny Goblin pattern)
- **Phase 3:** Core Substrate & Module Dispatcher Architecture
- **Phase 4:** Filesystem & Directed Backup Engine (FUSE / SAF)
- **Phase 5:** Media & Utility Modules (`nomad-camera`, `nomad-clipboard`, `nomad-notify`)
- **Phase 6:** Headless Server Daemon & Oriel Applications
- **Phase 7:** Persistent Roaming & NAT Splicing Relay

## 🛠 Getting Started

### Prerequisites

- [Zig 0.16.0](https://ziglang.org/download/)

### Build & Run

```bash
# Build the core library and CLI
zig build

# Run unit tests
zig build test
```
