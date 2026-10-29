#!/usr/bin/env bash
# Measures reads of one swarm folder file on the devices: download speed,
# bytes on the wire, and which devices served the blocks.
#
#   scripts/bench-devices.sh <swarm path> [reader ...]
#   scripts/bench-devices.sh Camera/VID_20220918_204314.mp4 doew ridge poco
#   IDLE=60 scripts/bench-devices.sh - doew plex     idle traffic for 60 s instead
#   WARM=ridge scripts/bench-devices.sh <path> doew  read on ridge first (a 2nd holder)
#
# Readers: doew, plex (SSH), ridge (this machine), poco (adb). Each reader's
# node is stopped (service, app), the benchmark node runs with the same
# config and identity (`nomadfs --bench-read <path> --bench-cold`: read
# cache emptied first, so the read goes to the network), then the node is
# started again. Results are printed per reader and saved under
# .agents/bench/<timestamp>/.
#
# The binaries are the ones built from this checkout (deploy the servers
# first: scripts/deploy-servers.sh), so the benchmark runs the code under test.
set -euo pipefail
cd "$(dirname "$0")/.."

path=${1:?usage: bench-devices.sh <swarm path|-> [reader ...]}
shift
readers=("$@")
[ ${#readers[@]} -gt 0 ] || readers=(doew plex ridge poco)
out=.agents/bench/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"

if [ -n "${IDLE:-}" ]; then
  bench_args=(--bench-idle "$IDLE")
else
  bench_args=(--bench-read "$path" --bench-cold --bench-wait "${WAIT:-40}")
fi
quote() { printf "%q " "$@"; }
ssh_q() { ssh -o ConnectTimeout=15 "$@" 2> >(grep -v -e "post-quantum" -e "store now, decrypt later" -e "may need to be upgraded" >&2); }

# Runs the benchmark on one reader, the node stopped around it; prints the
# key=value result on stdout.
run_on() {
  local host=$1
  case "$host" in
    plex)
      ssh_q plex "systemctl --user stop nomadfs; ~/.local/bin/nomadfs $(quote "${bench_args[@]}") --config ~/.nomadfs/nomadfs.conf 2>/tmp/bench.err; rc=\$?; systemctl --user start nomadfs; exit \$rc"
      ;;
    doew)
      ssh_q doew "systemctl stop nomadfs; /usr/local/bin/nomadfs $(quote "${bench_args[@]}") --config /etc/nomadfs/nomadfs.conf 2>/tmp/bench.err; rc=\$?; systemctl start nomadfs; exit \$rc"
      ;;
    ridge)
      local was_running=
      if pgrep -x nomadfs-gui >/dev/null; then
        was_running=1
        pkill -x nomadfs-gui || true
        for _ in $(seq 50); do pgrep -x nomadfs-gui >/dev/null || break; sleep 0.1; done
      fi
      local rc=0
      ./zig-out/bin/nomadfs "${bench_args[@]}" --config ~/.nomadfs/nomadfs.conf 2>"$out/ridge.err" || rc=$?
      if [ -n "$was_running" ]; then
        local log="${XDG_STATE_HOME:-$HOME/.local/state}/nomadfs/nomadfs-gui.log"
        nohup setsid ~/.local/bin/nomadfs-gui >>"$log" 2>&1 </dev/null &
      fi
      return $rc
      ;;
    poco)
      # The app's own identity and config, run as the app (run-as); the
      # static aarch64 build runs on Android.
      local app=net.nomadfs.app
      adb push -q "$aarch64_bin" /data/local/tmp/nomadfs-bench >/dev/null
      adb shell am force-stop $app
      adb shell "run-as $app sh -c 'cp /data/local/tmp/nomadfs-bench files/nomadfs-bench && chmod 700 files/nomadfs-bench && cd files && ./nomadfs-bench $(quote "${bench_args[@]}") --config /data/user/0/$app/files/nomadfs.conf 2>/dev/null; rc=\$?; rm -f nomadfs-bench; exit \$rc'"
      local rc=$?
      adb shell monkey -p $app -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
      return $rc
      ;;
    *) echo "unknown reader: $host" >&2; return 2 ;;
  esac
}

echo "==> Building"
zig build -Doptimize=ReleaseSafe >/dev/null
aarch64_dir=$(mktemp -d)
trap 'rm -rf "$aarch64_dir"' EXIT
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -p "$aarch64_dir" >/dev/null
aarch64_bin=$aarch64_dir/bin/nomadfs

if [ -n "${WARM:-}" ] && [ -z "${IDLE:-}" ]; then
  echo "==> Warming $WARM (it reads the file once and keeps it in its read cache)"
  saved=("${bench_args[@]}")
  bench_args=(--bench-read "$path" --bench-wait "${WAIT:-40}")
  run_on "$WARM" >"$out/warm-$WARM.txt" || echo "  warming $WARM failed" >&2
  bench_args=("${saved[@]}")
fi

for r in "${readers[@]}"; do
  echo "==> $r"
  if run_on "$r" >"$out/$r.txt"; then
    sed 's/^/  /' "$out/$r.txt"
  else
    echo "  failed (see $out/$r.txt)" >&2
  fi
done

# One table of the headline numbers.
echo
printf "%-8s %10s %10s %14s %14s %8s\n" reader MiB/s seconds wire_received wire_sent fetched
for r in "${readers[@]}"; do
  f="$out/$r.txt"
  [ -s "$f" ] || continue
  get() { sed -n "s/^$1=//p" "$f" | head -n1; }
  printf "%-8s %10s %10s %14s %14s %8s\n" "$r" "$(get mib_per_s)" "$(get seconds)" "$(get wire_received)" "$(get wire_sent)" "$(get fetched_blocks)"
done
echo "Saved in $out"
