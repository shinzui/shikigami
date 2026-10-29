#!/usr/bin/env bash
# Native directory provisioning only. Full account, admission and recovery
# qualification belongs to the accepted supervisor fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="shikigami-provision-probe-$(date -u +%Y%m%d%H%M%S)-$$"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() { if "$created"; then container stop --time 5 "$name" >/dev/null; fi; }
trap cleanup EXIT
container run --rm --detach --name "$name" --cpus 2 --memory 2G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
prefix=/var/lib/shikigami-provision-probe
container exec "$name" mkdir -p "$prefix"
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-provision-probe/files.c' <shikigami-workers/cbits/workspace-files.c
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-provision-probe/probe.c' <tests/workspace/provision-probe.c
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-provision-probe/workspace-systemd-profile.h' <shikigami-workers/cbits/workspace-systemd-profile.h
container exec --interactive "$name" /usr/bin/timeout 180 /bin/bash -s <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends dbus gcc libc6-dev jq busybox-static >/dev/null 2>&1
systemctl daemon-reload
systemctl start dbus
prefix=/var/lib/shikigami-provision-probe
chmod 700 "$prefix"
groupadd --gid 62001 workspace-probe
useradd --uid 62001 --gid 62001 --no-create-home --shell /usr/sbin/nologin workspace-probe
cc -static -O2 -Wall -Wextra -Werror -o "$prefix/probe" "$prefix/files.c" "$prefix/probe.c"
mkdir -m 700 "$prefix/fixtures"
"$prefix/probe" "$prefix/fixtures"
mkdir -p "$prefix/root"/{bin,etc,proc,dev,tmp,workspace,scratch} "$prefix/scratch"
cp "$prefix/probe" "$prefix/root/bin/probe"
cp /bin/busybox "$prefix/root/bin/busybox"
chown 62001:62001 "$prefix/scratch"
properties=(-p RuntimeMaxSec=10 -p "RootDirectory=$prefix/root" -p User=62001 -p Group=62001 -p WorkingDirectory=/workspace -p "BindPaths=$prefix/fixtures/good:/workspace $prefix/scratch:/scratch")
while IFS= read -r property; do properties+=(-p "$property"); done < <("$prefix/probe" --profile | jq -r '.[]')
run_service() {
  local unit=$1
  shift
  # Preserve the production RemainAfterExit setting. A direct --wait would
  # continue waiting for this deliberately retained successful unit to stop.
  systemd-run --quiet --unit="$unit" "${properties[@]}" -p StandardInput=null -p StandardOutput=null -p StandardError=null -- "$@"
  for _ in {1..200}; do
    [[ $(systemctl show "$unit" -p SubState --value) == exited ]] && break
    sleep 0.05
  done
  [[ $(systemctl show "$unit" -p SubState --value) == exited && $(systemctl show "$unit" -p ExecMainCode --value) == 1 && $(systemctl show "$unit" -p ExecMainStatus --value) == 0 && $(systemctl show "$unit" -p MainPID --value) == 0 ]]
  systemctl stop "$unit"
}
run_service shikigami-provision-unsupported /bin/probe --unsupported
echo 'PASS an unprivileged process cannot provision an identity or directory'
run_service shikigami-provision-write /bin/busybox sh -c 'test "$(cat /workspace/file)" = fixture && test "$(cat /workspace/published)" = fixture && printf writable >/workspace/published && printf updated >/workspace/file && printf created >/workspace/new && printf scratch >/scratch/new'
[[ $(cat "$prefix/fixtures/good/file") == updated && $(cat "$prefix/fixtures/good/new") == created && $(stat -c %u "$prefix/fixtures/good/new") == 62001 ]]
echo 'PASS the reserved unprivileged service identity reads and writes the provisioned tree and scratch under the production profile'
echo 'Native provisioning substrate passed (11 cases); full account/admission/restart qualification remains separate.'
GUEST
