#!/usr/bin/env bash
# Updates the always-on NomadFS nodes over SSH and restarts their service:
#
#   plex   aarch64  ~/.local/bin/nomadfs       systemctl --user (rockpi)
#   doew   x86_64   /usr/local/bin/nomadfs     systemctl (root; the relay)
#
#   scripts/deploy-servers.sh                 build from this checkout, deploy to all
#   scripts/deploy-servers.sh plex            only some hosts
#   RELEASE=0.2.5 scripts/deploy-servers.sh   the published release's binaries
#                                             (checked against its SHA256SUMS)
#
# For each host: copy the binary next to the installed one, check it runs
# there (`--help`; a binary built for the wrong CPU dies with SIGILL),
# keep the old one as nomadfs.prev, swap, restart, and check the same
# process is still running 10 s later. If not, the old binary goes back.
set -euo pipefail
cd "$(dirname "$0")/.."

# host  arch  binary path  systemctl scope (--user or system)
hosts_table() {
  cat <<'EOF'
plex aarch64 /home/rockpi/.local/bin/nomadfs --user
doew x86_64 /usr/local/bin/nomadfs system
EOF
}

want=("$@")
[ ${#want[@]} -gt 0 ] || mapfile -t want < <(hosts_table | cut -d' ' -f1)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
step() { echo "==> $*"; }

# The binaries, one per arch: $work/nomadfs-<arch>.
if [ -n "${RELEASE:-}" ]; then
  step "Downloading NomadFS $RELEASE"
  gh release download "v$RELEASE" --dir "$work" \
    --pattern "nomadfs-$RELEASE-x86_64-linux" --pattern "nomadfs-$RELEASE-aarch64-linux" --pattern SHA256SUMS
  (cd "$work" && grep -E "nomadfs-$RELEASE-(x86_64|aarch64)-linux\$" SHA256SUMS | sha256sum -c --quiet)
  for arch in x86_64 aarch64; do mv "$work/nomadfs-$RELEASE-$arch-linux" "$work/nomadfs-$arch"; done
else
  version=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/node_info.zig)
  step "Building NomadFS $version from this checkout"
  # Same targets as scripts/release.sh: baseline x86_64, static musl.
  zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl -Dcpu=baseline -p "$work/x86_64"
  zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -p "$work/aarch64"
  for arch in x86_64 aarch64; do cp "$work/$arch/bin/nomadfs" "$work/nomadfs-$arch"; done
fi

ssh_q() { ssh -o ConnectTimeout=15 "$@" 2>&1 | grep -v -e "post-quantum" -e "store now, decrypt later" -e "may need to be upgraded"; }

failed=()
for host in "${want[@]}"; do
  line=$(hosts_table | awk -v h="$host" '$1 == h') || true
  if [ -z "$line" ]; then echo "Unknown host: $host" >&2; failed+=("$host"); continue; fi
  read -r _ arch path scope <<<"$line"
  ctl="systemctl"; [ "$scope" = --user ] && ctl="systemctl --user"
  step "$host ($arch): $path"
  scp -q -o ConnectTimeout=15 "$work/nomadfs-$arch" "$host:$path.new" 2>&1 | grep -v -e "post-quantum" -e "store now" -e "may need" || true
  # shellcheck disable=SC2087 # expanded here on purpose
  if ! ssh_q "$host" bash -s <<EOF
set -e
chmod +x "$path.new"
if ! "$path.new" --help >/dev/null 2>&1; then
  echo "  the new binary doesn't run here (exit \$?); nothing changed"
  rm -f "$path.new"
  exit 1
fi
# Renames, never writes over a running binary ("Text file busy").
cp "$path" "$path.prev"
mv "$path.new" "$path"
$ctl restart nomadfs
sleep 2
pid=\$($ctl show nomadfs -p MainPID --value)
sleep 8
# Up, and the same process: a crash loop would have a new one.
if [ "\$($ctl is-active nomadfs)" != active ] || [ "\$($ctl show nomadfs -p MainPID --value)" != "\$pid" ] || [ "\$pid" = 0 ]; then
  echo "  the service didn't stay up; putting the previous binary back"
  cp "$path.prev" "$path.rollback"
  mv "$path.rollback" "$path"
  $ctl restart nomadfs
  exit 1
fi
echo "  running: \$(sha256sum "$path" | cut -c1-16)…, previous kept as $path.prev"
EOF
  then failed+=("$host"); fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "Not updated: ${failed[*]}" >&2
  exit 1
fi
echo "Updated: ${want[*]}"
