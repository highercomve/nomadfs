#!/usr/bin/env bash
# The WebDAV mount works on this machine: a node serves its swarm folder,
# and files are written, read, renamed and deleted through it.
#
#   scripts/webdav-smoke.sh <nomadfs binary> mount   macOS: mount_webdav, then cp/mv/rm
#   scripts/webdav-smoke.sh <nomadfs binary> serve   anywhere: curl against --webdav
set -euo pipefail
bin=${1:-zig-out/bin/nomadfs}
mode=${2:-serve}
dir=$(mktemp -d)
export HOME="$dir" USERPROFILE="$dir"
cat > "$dir/smoke.conf" <<CONF
nickname = "davsmoke"
swarm_key = "$(printf '0%.0s' $(seq 1 64))"
port = 47322
storage_path = "$dir/data"
CONF
port=47390
log="$dir/node.log"
cleanup() {
  [ -n "${pid:-}" ] && kill -INT "$pid" 2>/dev/null && sleep 3
  cat "$log" | tail -5 || true
  rm -rf "$dir" || true
}
trap cleanup EXIT
printf 'hello from webdav\n' > "$dir/hello.txt"

if [ "$mode" = mount ]; then
  mnt="$dir/NomadFS"
  "$bin" --mount "$mnt" "$dir/smoke.conf" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do mount | grep -q " on $mnt " && break; sleep 1; done
  mount | grep " on $mnt "
  ls "$mnt"
  test -d "$mnt/Swarm"
  cp "$dir/hello.txt" "$mnt/Swarm/hello.txt"
  mkdir "$mnt/Swarm/notes"
  mv "$mnt/Swarm/hello.txt" "$mnt/Swarm/notes/moved.txt"
  cmp "$dir/hello.txt" "$mnt/Swarm/notes/moved.txt"
  ls -la "$mnt/Swarm/notes"
  rm "$mnt/Swarm/notes/moved.txt"
  rmdir "$mnt/Swarm/notes"
  test ! -e "$mnt/Swarm/notes"
  # Finder's metadata files stay out of the swarm.
  test -z "$(ls -A "$mnt/Swarm")"
else
  "$bin" --webdav "$port" "$dir/smoke.conf" > "$log" 2>&1 &
  pid=$!
  url="http://127.0.0.1:$port"
  for _ in $(seq 1 30); do curl -sf -X OPTIONS "$url/" > /dev/null && break; sleep 1; done
  test "$(curl -s -o /dev/null -w '%{http_code}' -T "$dir/hello.txt" "$url/Swarm/hello.txt")" = 201
  test "$(curl -s -o /dev/null -w '%{http_code}' -X MKCOL "$url/Swarm/notes")" = 201
  test "$(curl -s -o /dev/null -w '%{http_code}' -X MOVE -H "Destination: $url/Swarm/notes/moved.txt" "$url/Swarm/hello.txt")" = 201
  curl -sf "$url/Swarm/notes/moved.txt" | cmp - "$dir/hello.txt"
  curl -sf -X PROPFIND -H 'Depth: 1' "$url/Swarm/notes/" | grep -q moved.txt
  test "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$url/Swarm/notes")" = 204
  test "$(curl -s -o /dev/null -w '%{http_code}' "$url/Swarm/notes/moved.txt")" = 404
fi
echo "webdav smoke ($mode): ok"
