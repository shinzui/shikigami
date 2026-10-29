#!/usr/bin/env bash
# Substrate experiment only; this does not install or qualify a supervisor.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="shikigami-root-probe-$(date -u +%Y%m%d%H%M%S)-$$"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() { if "$created"; then container stop --time 5 "$name" >/dev/null; fi; }
trap cleanup EXIT
container run --rm --detach --name "$name" --cpus 2 --memory 4G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
container exec --interactive "$name" /bin/sh -c 'mkdir -p /var/lib/shikigami-root-probe && cat >/var/lib/shikigami-root-probe/probe.c' <tests/workspace/root-isolation-probe.c
container exec --interactive "$name" /usr/bin/timeout 300 /bin/bash -s <<'GUEST'
set -euo pipefail
[[ $(ps -p 1 -o comm=) == systemd ]]
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends dbus gcc libc6-dev nix-bin sudo ca-certificates >/dev/null 2>&1
systemctl daemon-reload
systemctl start dbus
nix --version
sudo -n true
groupadd --gid 62001 workspace-probe
useradd --uid 62001 --gid 62001 --no-create-home --shell /usr/sbin/nologin workspace-probe
getent group nixbld >/dev/null || groupadd --system nixbld
useradd --system --gid nixbld --groups nixbld --home-dir /var/empty --no-create-home --shell /usr/sbin/nologin nixbld-probe
prefix=/var/lib/shikigami-root-probe
root="$prefix/root"
workspace="$prefix/workspace"
scratch="$prefix/scratch"
mkdir -p "$root"/{bin,etc,proc,dev,tmp,workspace,scratch} "$workspace" "$scratch" "$prefix/sibling"
printf secret >"$prefix/host-secret"
printf secret >"$prefix/sibling/secret"
printf immutable >"$root/etc/immutable"
chmod 0777 "$root/etc/immutable"
chown 62001:62001 "$workspace" "$scratch"
cc -static -Wall -Wextra -Werror -o "$root/bin/isolation-probe" "$prefix/probe.c"
# Nix materializes the closure. Do not inspect or traverse /nix/store.
# The revision matches this repository's flake.lock.
reference='github:NixOS/nixpkgs/d5dfd8e6716dde34398bc14bc87c10dece9c8c68#busybox'
nix --extra-experimental-features 'nix-command flakes' build --no-link --no-write-lock-file "$reference"
tool_path=$(nix --extra-experimental-features 'nix-command flakes' path-info "$reference")
nix --extra-experimental-features 'nix-command flakes' copy --to "local?root=$root" "$tool_path"
properties=(
  -p Type=exec -p Restart=no -p RuntimeMaxSec=20 -p TimeoutStopSec=1
  -p KillMode=control-group -p SendSIGKILL=yes
  -p "RootDirectory=$root" -p WorkingDirectory=/workspace
  -p "BindPaths=$workspace:/workspace $scratch:/scratch"
  -p User=62001 -p Group=62001 -p UMask=0077
  -p ProtectSystem=strict -p 'ReadWritePaths=/workspace /scratch'
  -p PrivateNetwork=yes -p PrivatePIDs=yes -p PrivateDevices=yes
  -p NoNewPrivileges=yes -p CapabilityBoundingSet=
  -p ProtectControlGroups=yes -p ProtectKernelTunables=yes
  -p ProtectKernelModules=yes -p ProtectKernelLogs=yes
  -p RestrictNamespaces=yes -p RestrictAddressFamilies=AF_UNIX
  -p 'SystemCallFilter=~@mount @privileged @reboot @swap @module @raw-io @debug'
  -p SystemCallErrorNumber=EPERM
  -p ProtectProc=invisible -p ProcSubset=pid -p TasksMax=64 -p MemoryMax=128M
)
systemd-run --unit=shikigami-root-isolation --wait --pipe "${properties[@]}" /bin/isolation-probe || { journalctl -u shikigami-root-isolation -n 12 --no-pager; exit 1; }
systemd-run --unit=shikigami-root-nix --wait --pipe "${properties[@]}" "$tool_path/bin/busybox" sh -c 'printf nix-closure >/workspace/nix-closure'
[[ $(cat "$workspace/nix-closure") == nix-closure ]]
echo 'PASS Nix closure executes in the immutable root'
systemd-run --unit=shikigami-root-descendant "${properties[@]}" -p RemainAfterExit=yes -p StandardOutput=null -p StandardError=null /bin/isolation-probe descendant
for _ in {1..100}; do
  [[ -f "$workspace/command-exited" ]] && break
  sleep 0.05
done
[[ -f "$workspace/descendant" ]]
[[ -f "$workspace/command-exited" ]]
[[ $(systemctl show shikigami-root-descendant -p MainPID --value) != 0 ]]
cgroup=$(systemctl show shikigami-root-descendant -p ControlGroup --value)
[[ "$cgroup" == /system.slice/shikigami-root-descendant.service ]]
[[ $(awk '$1 == "populated" {print $2}' "/sys/fs/cgroup$cgroup/cgroup.events") == 1 ]]
before=$(wc -c <"$workspace/descendant")
sleep 0.3
[[ $(wc -c <"$workspace/descendant") -gt "$before" ]]
echo 'PASS detached descendant remains active after its command parent exits'
systemctl stop shikigami-root-descendant
if [[ -f "/sys/fs/cgroup$cgroup/cgroup.events" ]]; then
  [[ $(awk '$1 == "populated" {print $2}' "/sys/fs/cgroup$cgroup/cgroup.events") == 0 ]]
fi
before=$(wc -c <"$workspace/descendant")
sleep 0.3
[[ $(wc -c <"$workspace/descendant") == "$before" ]]
echo 'PASS whole-cgroup stop settles a SIGTERM-ignoring detached child'
echo 'Root substrate probe passed (13 checks); independent supervisor and receipt recovery remain unqualified.'
GUEST
