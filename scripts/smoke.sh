#!/usr/bin/env bash
# A node starts and works on this machine: a fresh swarm, a pairing ticket
# (keys, addresses), then the node runs for a few seconds. CI runs it on
# Linux, macOS and Windows (Git Bash).   scripts/smoke.sh [nomadfs binary]
set -euo pipefail
bin=${1:-zig-out/bin/nomadfs}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
# Its own home: device keys and the node lock live there.
export HOME="$dir" USERPROFILE="$dir"
cat > "$dir/smoke.conf" <<CONF
nickname = "smoke"
swarm_key = "$(printf '0%.0s' $(seq 1 64))"
port = 47321
storage_path = "$dir/data"
CONF
"$bin" --version
"$bin" --pair "$dir/smoke.conf" > "$dir/pair.txt"
grep -q "nomadfs://pair" "$dir/pair.txt"
# It knows its own addresses: the ticket lists one besides loopback.
addrs=$(grep -o "nomadfs://pair[^ ]*" "$dir/pair.txt" | head -1 | sed -n 's/.*&a=\([^&]*\).*/\1/p')
echo "ticket addresses: $addrs"
echo "$addrs" | grep -qv "^127\.0\.0\.1"
"$bin" --bench-idle 5 "$dir/smoke.conf"
echo "smoke: ok"
