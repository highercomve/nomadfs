# Operational & Deployment Guide

## 1. Prerequisites

NomadFS is designed to run on a wide range of hardware, from Raspberry Pis to high-end servers.

### Hardware Requirements
- **CPU**: x86_64 or ARM64 (aarch64)
- **RAM**: Minimum 512MB
- **Disk**: Dependent on stored data size. SSD recommended for performance.

### OS Requirements
- Linux (Kernel 5.4+)
- macOS (12+)
- Windows (10+, mostly for client mode)

## 2. Installation

We provide pre-compiled binaries for common platforms.

### From Source
```bash
git clone https://github.com/highercomve/nomadfs.git
cd nomadfs
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/nomadfs /usr/local/bin/
```

### Docker
```bash
docker pull highercomve/nomadfs:latest
```

## 3. Running a Storage Node

A storage node participates in the DHT and stores blocks for the network.

### Step 1: Generate Configuration
```bash
nomadfs init --name "MyServer" --path /var/lib/nomadfs
```
This generates `nomadfs.conf` in the current directory.

### Step 2: Edit Configuration
Ensure `storage.enabled = true` and set a secure `swarm_key`.

### Step 3: Run the Daemon
```bash
nomadfs run --config /etc/nomadfs/nomadfs.conf
```

### Systemd Service Example
Create `/etc/systemd/system/nomadfs.service`:
```ini
[Unit]
Description=NomadFS Storage Node
After=network.target

[Service]
ExecStart=/usr/local/bin/nomadfs run --config /etc/nomadfs/nomadfs.conf
Restart=always
User=nomadfs

[Install]
WantedBy=multi-user.target
```

## 4. Running a Client Node

Client nodes do not store data for others but can read/write to the swarm.

1. Set `storage.enabled = false` in `nomadfs.conf`.
2. Connect to a known bootstrap peer (e.g., your own Storage Node).

## 5. Troubleshooting

- **Check Logs**: Logs are printed to stdout/stderr. Redirect to a file or use journald.
- **Port Forwarding**: Ensure TCP port 9000 (default) is open.
- **Connectivity**: Use `telnet` or `nc` to verify connectivity to bootstrap peers.
