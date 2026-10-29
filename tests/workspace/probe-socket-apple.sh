#!/usr/bin/env bash
# Listener/peer substrate only; this is not the accepted supervisor restart gate.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="shikigami-socket-probe-$(date -u +%Y%m%d%H%M%S)-$$"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() { if "$created"; then container stop --time 5 "$name" >/dev/null; fi; }
trap cleanup EXIT
container run --rm --detach --name "$name" --cpus 2 --memory 2G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
container exec "$name" mkdir -p /var/lib/shikigami-socket-probe
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-socket-probe/socket.c' <shikigami-workers/cbits/workspace-socket.c
container exec --interactive "$name" /bin/sh -c 'cat >/var/lib/shikigami-socket-probe/probe.c' <tests/workspace/socket-activation-probe.c
container exec --interactive "$name" /usr/bin/timeout 180 /bin/bash -s <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends dbus gcc libc6-dev libsystemd-dev pkg-config python3 >/dev/null 2>&1
systemctl daemon-reload
systemctl start dbus
prefix=/var/lib/shikigami-socket-probe
cc -Wall -Wextra -Werror -o "$prefix/probe" "$prefix/socket.c" "$prefix/probe.c" $(pkg-config --cflags --libs libsystemd)
install -d -m 700 "$prefix/intake"
cat >/etc/systemd/system/shikigami-socket-probe.socket <<UNIT
[Socket]
ListenStream=$prefix/intake/rpc
SocketMode=0600
DirectoryMode=0700
RemoveOnStop=yes
UNIT
cat >/etc/systemd/system/shikigami-socket-probe.service <<UNIT
[Service]
Type=exec
ExecStart=$prefix/probe $prefix/intake/rpc $prefix/count
Restart=on-failure
RestartSec=0.1
TimeoutStartSec=5
TimeoutStopSec=1
RuntimeMaxSec=60
StandardOutput=null
StandardError=null
UNIT
systemctl daemon-reload
systemctl start shikigami-socket-probe.socket
[[ $(stat -c %a "$prefix/intake") == 700 && $(stat -c %a "$prefix/intake/rpc") == 600 ]]
call() {
  python3 - "$prefix/intake/rpc" <<'PY'
import socket,sys
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as peer:
    peer.settimeout(5)
    peer.connect(sys.argv[1])
    peer.sendall(b'x')
    assert peer.recv(2)==b'ok'
PY
}
call
[[ $(cat "$prefix/count") == 1 ]]
echo 'PASS exact filesystem Unix listener adoption, nonblocking/CLOEXEC descriptors and kernel peer credentials'
before=$(stat -c '%d:%i' "$prefix/intake/rpc")
old=$(systemctl show shikigami-socket-probe.service -p MainPID --value)
systemctl kill --signal=KILL --kill-whom=main shikigami-socket-probe.service
for _ in {1..100}; do
  current=$(systemctl show shikigami-socket-probe.service -p MainPID --value)
  [[ "$current" != 0 && "$current" != "$old" ]] && break
  sleep 0.05
done
[[ "$current" != 0 && "$current" != "$old" ]]
call
[[ $(cat "$prefix/count") == 11 && $(stat -c '%d:%i' "$prefix/intake/rpc") == "$before" ]]
echo 'PASS manager retains the same private listener through SIGKILL and independent service restart'
systemctl stop shikigami-socket-probe.socket shikigami-socket-probe.service
if "$prefix/probe" "$prefix/intake/rpc" "$prefix/count"; then exit 1; else [[ $? == 78 ]]; fi
[[ $(cat "$prefix/count") == 11 ]]
echo 'PASS missing manager activation refuses without accepting requests'
cat >/etc/systemd/system/shikigami-wrong-socket.socket <<UNIT
[Socket]
ListenStream=$prefix/intake/other
SocketMode=0600
UNIT
cat >/etc/systemd/system/shikigami-wrong-socket.service <<UNIT
[Service]
ExecStart=$prefix/probe $prefix/intake/rpc $prefix/count
StandardOutput=null
StandardError=null
UNIT
systemctl daemon-reload
systemctl start shikigami-wrong-socket.socket
python3 - "$prefix/intake/other" <<'PY'
import socket,sys
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as peer:
    peer.settimeout(3)
    peer.connect(sys.argv[1])
PY
for _ in {1..100}; do
  [[ $(systemctl show shikigami-wrong-socket.service -p ExecMainStatus --value) == 64 ]] && break
  sleep 0.05
done
[[ $(systemctl show shikigami-wrong-socket.service -p ExecMainStatus --value) == 64 && $(cat "$prefix/count") == 11 ]]
echo 'PASS an activated listener at another path cannot impersonate the configured endpoint'
echo 'Socket activation substrate passed (4 cases); full Haskell supervisor and accepted-attempt restart remain unqualified.'
GUEST
