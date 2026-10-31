#!/usr/bin/env bash
# A device "outside the house", on the public relay node itself: a NomadFS
# node in a network namespace that reaches only the relay's public address
# (no Tailscale, no private ranges) and that nothing can dial, like a phone
# behind its carrier's NAT. It joins the swarm with the relay's swarm key and
# has to reach the home devices through the relay.
#
#   ssh doew 'bash -s' < scripts/outside-test.sh [minutes] [public ip] [relay port]
#   BIN=/tmp/nomadfs-test: run that build instead of the installed one
#
# Every 10 s it records the devices the test node lists (its WebDAV root, the
# directory the app browses) and how many connections it holds. Output on
# stdout; the node's log is printed at the end. Everything is removed on exit.
set -euo pipefail
minutes=${1:-5}
ip_pub=${2:-$(ip -4 -o addr show dev eth0 scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}
relay_port=${3:-7865}
conf_src=/etc/nomadfs/nomadfs.conf
bin=${BIN:-$(command -v nomadfs || echo /usr/local/bin/nomadfs)}
ns=phonesim
dir=/tmp/phonesim
port=14799

cleanup() {
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null && sleep 1
  ip netns del $ns 2>/dev/null || true
  ip link del vps0 2>/dev/null || true
  nft delete table inet phonesim 2>/dev/null || true
  rm -rf "$dir"
}
trap cleanup EXIT
cleanup

ip netns add $ns
ip link add vps0 type veth peer name vps1
ip link set vps1 netns $ns
ip addr add 10.250.0.1/30 dev vps0; ip link set vps0 up
ip netns exec $ns ip addr add 10.250.0.2/30 dev vps1
ip netns exec $ns ip link set vps1 up
ip netns exec $ns ip link set lo up
ip netns exec $ns ip route add default via 10.250.0.1

# Out: only the relay's public address. In: nothing new (the carrier's NAT).
nft -f - <<EOF
table inet phonesim {
  chain ps_forward {
    type filter hook forward priority -10; policy accept;
    iifname "vps0" drop
    oifname "vps0" ct state new drop
  }
  chain ps_output {
    type filter hook output priority -10; policy accept;
    oifname "vps0" ct state new drop
  }
  chain ps_input {
    type filter hook input priority -10; policy accept;
    iifname "vps0" ip daddr != $ip_pub drop
  }
}
EOF

mkdir -p "$dir/home"
key=$(sed -n 's/^swarm_key *= *"\(.*\)"/\1/p' $conf_src)
cat > "$dir/nomadfs.conf" <<EOF
nickname = "phonesim"
swarm_key = "$key"
port = $port
storage_path = "$dir/data"
enable_mdns = false
bootstrap_peers = ["tcp://$ip_pub:$relay_port"]
EOF
HOME="$dir/home" ip netns exec $ns "$bin" --webdav 47391 "$dir/nomadfs.conf" > "$dir/node.log" 2>&1 &
pid=$!

listing() {
  local url
  url=$(grep -o 'http://127.0.0.1:47391/[0-9a-f]*' "$dir/node.log" | head -1)
  [ -n "$url" ] || { echo "(starting)"; return; }
  ip netns exec $ns curl -s -m 20 -X PROPFIND -H 'Depth: 1' "$url/" | grep -o '<D:displayname>[^<]*' | sed 's/<D:displayname>//' | grep -v '^NomadFS$' | tr '\n' ' ' || true
}
conns() { ip netns exec $ns ss -tn state established | tail -n +2 | awk '{print $4}' | sort | uniq -c | tr '\n' ' '; }

end=$((SECONDS + minutes * 60))
while [ $SECONDS -lt $end ]; do
  kill -0 $pid 2>/dev/null || { echo "the node exited"; break; }
  echo "$(date -u +%T) lists: [$(listing)] tcp: $(conns)"
  sleep 10
done
echo "==== node log ===="
grep -vE "mDNS|Routing Table|^---|Local ID|Total Peers" "$dir/node.log" | tail -150
