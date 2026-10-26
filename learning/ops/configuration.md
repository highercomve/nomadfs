# Configuration Reference

This document details all available configuration options in `nomadfs.conf`.

## [node] Section

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `nickname` | string | "NomadNode" | A human-readable name for this node. Used in logs. |
| `swarm_key` | string (hex) | Required | 32-byte private key (64 hex chars). All nodes in a swarm MUST share this key. |

## [storage] Section

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | bool | `true` | If `true`, the node stores blocks for the network. If `false`, it acts as a client/gateway only. |
| `storage_path` | path | "./nomad_data" | Directory where blocks and internal DBs are stored. |

## [network] Section

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `port` | integer | 9000 | TCP port to listen on. |
| `listening_address` | string | "0.0.0.0" | Interface to bind to. |
| `bootstrap_peers` | list of strings | `[]` | List of multiaddrs (e.g., `["tcp://1.2.3.4:9000"]`) to connect to on startup. |
| `enable_mdns` | bool | `true` | Enable local network discovery via Multicast DNS. |
| `enable_autonat` | bool | `true` | Enable automatic reachability verification. |

## [debug] Section

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `log_level` | string | "info" | One of: "error", "warn", "info", "debug". |
