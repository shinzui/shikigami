#!/usr/bin/env bash
# Native collector qualification only; full supervisor RPC/admission is separate.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="shikigami-capture-probe-$(date -u +%Y%m%d%H%M%S)-$$"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() { if "$created"; then container stop --time 5 "$name" >/dev/null; fi; }
trap cleanup EXIT
container run --rm --detach --name "$name" --cpus 2 --memory 2G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
container exec "$name" mkdir -p /var/lib/shikigami-capture-probe
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-capture-probe/collector.c' <shikigami-workers/cbits/workspace-collector.c
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-capture-probe/descendant.c' <tests/workspace/root-isolation-probe.c
container exec --interactive "$name" /usr/bin/timeout 240 /bin/bash -s <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends dbus gcc libc6-dev libsystemd-dev pkg-config jq >/dev/null 2>&1
systemctl daemon-reload
systemctl start dbus
prefix=/var/lib/shikigami-capture-probe
cc -Wall -Wextra -Werror -DSHIKIGAMI_COLLECTOR_STANDALONE -o "$prefix/collector" "$prefix/collector.c" $(pkg-config --cflags --libs libsystemd)
mkdir -p "$prefix/root"/{bin,etc,proc,dev,tmp,workspace,scratch} "$prefix/workspace" "$prefix/scratch"
groupadd --gid 62001 workspace-probe
useradd --uid 62001 --gid 62001 --no-create-home --shell /usr/sbin/nologin workspace-probe
chown 62001:62001 "$prefix/workspace" "$prefix/scratch"
cc -static -Wall -Wextra -Werror -o "$prefix/root/bin/descendant" "$prefix/descendant.c"
cat >"$prefix/payload.c" <<'C'
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <signal.h>
int main(int argc, char **argv) {
  char bytes[8192]; memset(bytes, 'x', sizeof(bytes));
  int fd = open("/workspace/launch-count", O_WRONLY|O_CREAT|O_APPEND, 0600);
  if (fd < 0 || write(fd,"1",1)!=1) return 1;
  close(fd);
  if (argc == 2 && !strcmp(argv[1],"flood")) {
    for (int i=0;i<128;i++) if (write(1,bytes,sizeof(bytes))<0 || write(2,bytes,sizeof(bytes))<0) return 2;
    return 0;
  }
  signal(SIGTERM,SIG_IGN);
  for (int i=0;i<100;i++) { if (write(1,bytes,16)<0) return 3; usleep(100000); }
  return 0;
}
C
cc -static -Wall -Wextra -Werror -o "$prefix/root/bin/payload" "$prefix/payload.c"
props=(
  -p Type=exec -p Restart=no -p RemainAfterExit=yes -p RuntimeMaxSec=15 -p TimeoutStopSec=1
  -p KillMode=control-group -p SendSIGKILL=yes -p Slice=system.slice
  -p "RootDirectory=$prefix/root" -p WorkingDirectory=/workspace
  -p "BindPaths=$prefix/workspace:/workspace $prefix/scratch:/scratch"
  -p User=62001 -p Group=62001 -p ProtectSystem=strict -p 'ReadWritePaths=/workspace /scratch'
  -p PrivateNetwork=yes -p PrivatePIDs=yes -p PrivateDevices=yes
  -p NoNewPrivileges=yes -p CapabilityBoundingSet= -p ProtectControlGroups=yes
  -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p RestrictNamespaces=yes
  -p RestrictAddressFamilies=AF_UNIX
  -p 'SystemCallFilter=~@mount @privileged @reboot @swap @module @raw-io @debug'
  -p SystemCallErrorNumber=EPERM -p ProtectProc=invisible -p ProcSubset=pid
)
wait_file() {
  for _ in {1..200}; do [[ -f "$1" ]] && return 0; sleep 0.05; done
  [[ ! -f "$op/unresolved.json" ]] || cat "$op/unresolved.json"
  systemctl show "$capture" -p Result -p ExecMainStatus
  return 1
}
prepare() {
  id=$(printf '%064x' "$1")
  unit="shikigami-workspace-$id.service"
  capture="shikigami-capture-$id.service"
  fingerprint="sha256:$id"
  op="$prefix/operation-$id"
  mkdir -m 700 "$op"
  systemd-run --quiet --unit="$capture" -p Type=exec -p Restart=no -p RuntimeMaxSec=45 -p StandardOutput=null -p StandardError=null "$prefix/collector" "$op" "$unit" "$fingerprint" 1024 30
  wait_file "$op/ready"
}
launch() {
  systemd-run --quiet --unit="$unit" "${props[@]}" -p "Description=shikigami-workspace/1 $fingerprint" -p "StandardOutput=file:$op/stdout.pipe" -p "StandardError=file:$op/stderr.pipe" "$@"
}
prepare 1
launch /bin/payload flood
wait_file "$op/complete.json"
jq -e '.exitCode==0 and .outputComplete and .descendantsEmpty and (.stdoutBytes+.stderrBytes==1024) and (.stdoutTruncated or .stderrTruncated)' "$op/complete.json" >/dev/null
[[ $(wc -c <"$op/stdout") -le 1024 && $(wc -c <"$op/stderr") -le 1024 ]]
[[ $(wc -c <"$prefix/workspace/launch-count") == 1 ]]
echo 'PASS bounded prefixes drain excess stdout and stderr without blocking the command'
if launch /bin/payload flood >/dev/null 2>&1; then echo 'duplicate unit launched'; exit 1; fi
[[ $(wc -c <"$prefix/workspace/launch-count") == 1 ]]
echo 'PASS duplicate launch cannot repeat the retained unit'
prepare 2
launch /bin/descendant descendant
wait_file "$op/observed.json"
wait_file "$prefix/workspace/command-exited"
before=$(wc -c <"$prefix/workspace/descendant")
sleep 0.3
[[ $(wc -c <"$prefix/workspace/descendant") -gt "$before" && ! -f "$op/complete.json" ]]
printf cancel >"$op/cancel"
sync -f "$op/cancel"
systemctl stop "$unit"
wait_file "$op/complete.json"
jq -e '.termination=="ProcessCancelled" and .descendantsEmpty and .outputComplete' "$op/complete.json" >/dev/null
before=$(wc -c <"$prefix/workspace/descendant")
sleep 0.3
[[ $(wc -c <"$prefix/workspace/descendant") == "$before" ]]
echo 'PASS cancellation retains unit evidence and settles a detached SIGTERM-ignoring writer'
prepare 3
launch /bin/payload slow
wait_file "$op/observed.json"
systemctl kill --signal=KILL --kill-whom=main "$capture"
sleep 0.2
systemctl stop "$unit"
[[ ! -f "$op/complete.json" ]]
if "$prefix/collector" "$op" "$unit" "$fingerprint" 1024 30; then exit 1; fi
[[ ! -f "$op/complete.json" ]]
echo 'PASS collector loss is unresolved and cannot fabricate or recapture completion'
prepare 4
launch -p RuntimeMaxSec=1 /bin/payload slow
wait_file "$op/complete.json"
jq -e '.termination=="ProcessTimedOut" and .exitCode==137 and .descendantsEmpty and .outputComplete' "$op/complete.json" >/dev/null
echo 'PASS runtime timeout records the forced exit after whole-group settlement'
prepare 5
accepted="$fingerprint"
fingerprint="sha256:$(printf '%064x' 999)"
launch /bin/payload slow
fingerprint="$accepted"
wait_file "$op/unresolved.json"
[[ ! -f "$op/complete.json" && ! -f "$op/observed.json" ]]
systemctl stop "$unit"
echo 'PASS mismatched unit fingerprint cannot establish invocation or completion'
mkdir -m 755 "$prefix/not-private"
if "$prefix/collector" "$prefix/not-private" "$unit" "$fingerprint" 1024 30; then exit 1; fi
[[ ! -e "$prefix/not-private/unresolved.json" && ! -e "$prefix/not-private/ready" ]]
echo 'PASS an unqualified metadata directory receives no collector writes'
echo 'Collector probe passed (7 cases); supervisor RPC and PostgreSQL integration remain unqualified.'
GUEST
