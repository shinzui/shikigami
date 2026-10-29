#!/usr/bin/env bash
# Environment probe only: this does not qualify the durable supervisor.
set -euo pipefail
name="shikigami-workspace-probe-$(date -u +%Y%m%d%H%M%S)-$$"
# Reuse the installed fixture image after checking upstream releases. Kind v0.33.0
# publishes newer Kubernetes images; this environment probe needs only its
# empirically checked systemd 257 userspace, not Kubernetes compatibility.
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() {
  if "$created"; then container stop --time 5 "$name" >/dev/null; fi
}
trap cleanup EXIT
# ALL applies inside a disposable Linux VM with no host mounts or credentials.
# Individual workspace services drop all capabilities in the checks below.
container run --rm --detach --name "$name" --cpus 2 --memory 2G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
container exec --interactive "$name" /bin/bash -s <<'GUEST'
set -euo pipefail
[[ $(ps -p 1 -o comm=) == systemd ]]
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]
[[ -w /sys/fs/cgroup ]]
echo 'PASS systemd and writable cgroup v2'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y --no-install-recommends dbus >/dev/null 2>&1
systemctl daemon-reload
systemctl start dbus
# systemd expands dollars in ExecStart; use $$ for a literal shell dollar.
systemd-run --unit=shikigami-probe --wait --pipe \
  -p Type=exec -p Restart=no -p RuntimeMaxSec=15 -p TimeoutStopSec=2 \
  -p KillMode=control-group -p SendSIGKILL=yes \
  -p PrivateNetwork=yes -p PrivatePIDs=yes -p PrivateDevices=yes \
  -p NoNewPrivileges=yes -p CapabilityBoundingSet= \
  -p ProtectControlGroups=yes -p ProtectKernelTunables=yes -p ProtectKernelModules=yes \
  /bin/sh -c 'test "$$(ps -e -o comm= | wc -l)" -le 4; test "$$(wc -l </proc/net/route)" -eq 1; test "$$(awk "/^CapEff:/ {print \$2}" /proc/self/status)" = 0000000000000000'
echo 'PASS effective PID, network and capability isolation'
echo 'Environment probe passed (2 cases); durable supervisor qualification remains incomplete.'
GUEST
