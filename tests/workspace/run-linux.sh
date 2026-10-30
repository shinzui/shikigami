#!/usr/bin/env bash
# Destructive fixture work is confined to a disposable guest explicitly marked
# by its provisioner. This runner never enables production process admission.
set -eEuo pipefail
mode=${1:-}
runtime=${2:-}
[[ $# == 2 && ( "$mode" == --prototype || "$mode" == --provision ) && "$runtime" == /nix/store/* ]] || { echo 'Usage: run-linux.sh --prototype|--provision RUNTIME'; exit 64; }
[[ $(uname -s) == Linux && $(id -u) == 0 && -f /run/shikigami-workspace-prototype.disposable ]] || { echo 'REFUSED: a marked disposable Linux guest running as root is required'; exit 78; }
[[ $(ps -p 1 -o comm=) == systemd && $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]
sudo -n true
repo=$(cd "$(dirname "$0")/../.." && pwd)
umask 077
prefix=$(mktemp -d /var/lib/shikigami-prototype-XXXXXXXX)
chmod 711 "$prefix"
printf '%s\n' "$prefix" >/run/shikigami-workspace-prototype.prefix
task=${prefix##*/}
service="$task.service"
socket="$task.socket"
authority="$task-authority.service"
oauth="$task-oauth.service"
prototype="$runtime/bin/shikigami-workspace-prototype"
config="$prefix/config.json"
pg_bindir=$(/usr/bin/pg_config --bindir)
pg_started=false
cases=(duplicate worker-restart supervisor-restart cancellation completion-recovery denials capture-loss authority-denial)
cleanup() {
  status=$?
  trap - EXIT ERR
  systemctl stop "$socket" "$service" "$authority" "$oauth" >/dev/null 2>&1 || true
  for case_name in "${cases[@]}"; do
    systemctl stop "$task-$case_name.service" >/dev/null 2>&1 || true
    file="$prefix/status-$case_name.json"
    if [[ -f "$file" ]]; then
      for key in '.process.unit' '.capture'; do
        unit=$(jq -r "$key // empty" "$file")
        if [[ "$unit" =~ ^shikigami-(workspace|capture)-[0-9a-f]{64}\.service$ ]]; then systemctl stop "$unit" >/dev/null 2>&1 || true; fi
      done
    fi
  done
  if "$pg_started"; then runuser -u postgres -- "$pg_bindir/pg_ctl" -D "$prefix/pg" -m immediate -w stop >/dev/null 2>&1 || true; fi
  # Retain private evidence and reserved users until the disposable guest is
  # destroyed. Incomplete receipts never authorize production workspace cleanup.
  exit "$status"
}
trap cleanup EXIT
diagnose() {
  result=$?
  trap - ERR
  if "$pg_started"; then
    /usr/bin/psql "$connection" -Atc "SELECT (SELECT count(*) FROM shikigami.workspace_bindings), (SELECT count(*) FROM shikigami.workspace_bindings WHERE state='ready'), (SELECT count(*) FROM shikigami.workspace_process_profiles), (SELECT count(*) FROM shikigami.workspace_process_profiles WHERE ready)" >"$prefix/diagnostics.log" 2>&1 || true
    for uid in 64000 64001; do if getent passwd "$uid" >/dev/null; then echo "identity $uid present"; else echo "identity $uid absent"; fi; done >>"$prefix/diagnostics.log"
    for marker in "$prefix"/workspaces/*/metadata/profile-provision.json; do [[ ! -f "$marker" ]] || jq '{ready}' "$marker" >>"$prefix/diagnostics.log"; done
    for directory in "$prefix"/workspaces/*/files "$prefix"/workspaces/*/scratch; do [[ ! -d "$directory" ]] || stat -c '%u:%g:%a' "$directory" >>"$prefix/diagnostics.log"; done
  fi
  echo "FAIL workspace Linux runner at stage line $1"
  return "$result"
}
trap 'diagnose "$LINENO"' ERR
mkdir -p "$prefix/pg" "$prefix/pg-socket" "$prefix/sibling" "$prefix/rpc" "$prefix/root"/{bin,etc,proc,dev,tmp,workspace,scratch}
chown postgres:postgres "$prefix/pg" "$prefix/pg-socket"
chmod 700 "$prefix/pg" "$prefix/pg-socket"
chmod 755 "$prefix/root" "$prefix/root"/{bin,etc,proc,dev,workspace,scratch}
chmod 1777 "$prefix/root/tmp"
printf fixture-host-secret >"$prefix/host-secret"
printf fixture-sibling-secret >"$prefix/sibling/secret"
printf immutable >"$prefix/root/etc/probe-immutable"
chmod 666 "$prefix/root/etc/probe-immutable"
runuser -u postgres -- "$pg_bindir/initdb" -D "$prefix/pg" --auth=trust --no-locale --encoding=UTF8 >"$prefix/pg-init.log" 2>&1
port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0))
    print(listener.getsockname()[1])
PY
)
runuser -u postgres -- "$pg_bindir/pg_ctl" -D "$prefix/pg" -l "$prefix/pg/postgres.log" -o "-h 127.0.0.1 -p $port -k $prefix/pg-socket -F" -w start >"$prefix/pg-start.log" 2>&1
pg_started=true
connection="postgresql://postgres@127.0.0.1:$port/postgres?sslmode=disable"
DATABASE_URL="$connection" "$runtime/bin/shikigami-migrate" up >"$prefix/migrations.log" 2>&1
# Nix materializes both native arm64 closures; never traverse a store manually.
reference='github:NixOS/nixpkgs/d5dfd8e6716dde34398bc14bc87c10dece9c8c68#busybox'
nix --extra-experimental-features 'nix-command flakes' build --no-link --no-write-lock-file "$reference" >"$prefix/nix-tool.log" 2>&1
tool=$(nix --extra-experimental-features 'nix-command flakes' path-info "$reference")
expression="let pkgs = import (builtins.getFlake \"github:NixOS/nixpkgs/d5dfd8e6716dde34398bc14bc87c10dece9c8c68\") {}; in import $repo/nix/workspace-deadline.nix { inherit pkgs; }"
nix --extra-experimental-features 'nix-command flakes' build --impure --no-link --expr "$expression" >"$prefix/nix-guard.log" 2>&1
guard=$(nix --extra-experimental-features 'nix-command flakes' path-info --impure --expr "$expression")
nix --extra-experimental-features 'nix-command flakes' copy --to "local?root=$prefix/root" "$tool"
nix --extra-experimental-features 'nix-command flakes' copy --no-check-sigs --to "local?root=$prefix/root" "$guard"
ln -s "$tool/bin/busybox" "$prefix/root/bin/env"
cc -static -Wall -Wextra -Werror -O2 -DHOST_SECRET_PATH="\"$prefix/host-secret\"" -DSIBLING_SECRET_PATH="\"$prefix/sibling/secret\"" -o "$prefix/root/bin/probe" "$repo/tests/workspace/prototype-payload.c"
chmod 555 "$prefix/root/bin/probe"
image_digest=$( { printf '%s\n' "$tool" "$guard"; sha256sum "$prefix/root/bin/probe"; } | sha256sum | cut -d ' ' -f1)
# The fixture HTTP issuer listens only inside this guest on loopback.
authority_port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0))
    print(listener.getsockname()[1])
PY
)
systemd-run --quiet --unit="$authority" -p Type=exec -p Restart=no -p UMask=0077 -p StandardOutput=null -p "StandardError=file:$prefix/authority.log" -- "$prototype" authority "$prefix" "$authority_port"
for _ in {1..100}; do [[ -f "$prefix/issuer-public.txt" ]] && break; sleep 0.1; done
[[ -f "$prefix/issuer-public.txt" ]]
oauth_port=$(python3 - <<'PORT'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0))
    print(listener.getsockname()[1])
PORT
)
systemd-run --quiet --unit="$oauth" -p Type=exec -p Restart=no -p UMask=0077 -p StandardOutput=null -p "StandardError=file:$prefix/oauth.log" -- /usr/bin/python3 "$repo/tests/workspace/fixture-oauth.py" "$oauth_port" "$authority_port" "$prefix/http-status.log"
python3 - "$prefix" "$connection" "$authority_port" "$runtime" "$guard" "$image_digest" "$oauth_port" <<'PY'
import json,sys
from pathlib import Path
prefix,connection,port,runtime,guard,digest,oauth_port=sys.argv[1:]
p=Path(prefix)
(p/'directory.json').write_text(json.dumps([{'principal_id':'agent_01h000000000000000triage','handle':'fixture','lifecycle':'active','display_name':'Workspace fixture'}]))
config={'database':{'connection_string':connection},'directory':{'mode':'file','file':{'path':str(p/'directory.json')},'refresh_interval_seconds':1},'workspace':{'supervisor':{'socketPath':str(p/'rpc/supervisor.sock'),'users':[0],'workers':4,'timeoutSeconds':5}},'authorization':{'actions':{'mode':'kikan','kikan_en':{'base_url':f'http://127.0.0.1:{oauth_port}'},'shomei':{'base_url':f'http://127.0.0.1:{oauth_port}','client_id':'fixture'},'en':{'issuer_public_keys':(p/'issuer-public.txt').read_text(),'schema_hashes':'workspace-fixture-schema'},'caller_id':'workspace-fixture'}},'credentials':{'authorization':{'actions':{'shomei':{'client_secret':'fixture-secret'}}}}}
(p/'config.json').write_text(json.dumps(config))
(p/'native-spec.json').write_text(json.dumps({'format':1,'directory':prefix,'image':{'rootDirectory':str(p/'root'),'rootIdentity':'sha256:'+digest,'environmentExecutable':'/bin/env','deadlineExecutable':guard+'/bin/shikigami-workspace-deadline','collectorExecutable':runtime+'/bin/shikigami-workspace-collector'}}))
PY
"$prototype" native-provision "$config" "$prefix/native-spec.json" >"$prefix/provision.log" 2>&1
cat "$prefix/provision.log"
if [[ "$mode" == --provision ]]; then echo 'Coupled native provision probe passed (2 cases); full Linux prototype remains open.'; exit 0; fi
cat >"/etc/systemd/system/$socket" <<UNIT
[Socket]
ListenStream=$prefix/rpc/supervisor.sock
SocketMode=0600
DirectoryMode=0700
RemoveOnStop=yes
Service=$service
UNIT
cat >"/etc/systemd/system/$service" <<UNIT
[Unit]
Requires=$socket
After=$socket
[Service]
Type=exec
ExecStart=$runtime/bin/shikigami-workspace-supervisor --config $config
Restart=on-failure
RestartSec=0.2
KillMode=control-group
UMask=0077
StandardOutput=null
StandardError=file:$prefix/supervisor.log
UNIT
systemctl daemon-reload
systemctl start "$socket" "$service"
for _ in {1..200}; do
  if [[ -f "$prefix/supervisor.log" ]] && jq -Rse 'split("\n") | any(.[]; try (fromjson | .event=="workspace.supervisor.started") catch false)' "$prefix/supervisor.log" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
jq -Rse 'split("\n") | any(.[]; try (fromjson | .event=="workspace.supervisor.started") catch false)' "$prefix/supervisor.log" >/dev/null
prepare() { "$prototype" prepare "$config" "$prefix" "$1" "$2" >"$prefix/prepare-$1.log" 2>&1; }
inspect() { "$prototype" inspect "$config" "$prefix" "$1" >"$prefix/inspect-$1.log" 2>&1; }
start_worker() {
  systemd-run --quiet --unit="$task-$1.service" -p Type=exec -p Restart=no -p RemainAfterExit=yes -p UMask=0077 -p StandardOutput=null -p "StandardError=file:$prefix/worker-$1.log" -- "$prototype" worker "$config" "$prefix" "$1"
}
wait_ready() {
  for turn in {1..200}; do
    inspect "$1"
    files=$(jq -r '.files' "$prefix/status-$1.json")
    [[ -f "$files/src/command-ready" ]] && return 0
    if [[ "$turn" == 10 ]]; then
      unit=$(jq -r '.process.unit // empty' "$prefix/status-$1.json")
      if [[ "$unit" =~ ^shikigami-workspace-[0-9a-f]{64}\.service$ ]]; then
        systemctl show "$unit" --property=MainPID,ExecMainCode,ExecMainStatus,Result,ActiveEnterTimestamp,ControlGroup >>"$prefix/process-debug.log"
        cgroup=$(systemctl show "$unit" --property=ControlGroup --value)
        if [[ "$cgroup" == "/system.slice/$unit" && -f "/sys/fs/cgroup$cgroup/cgroup.procs" ]]; then
          while read -r pid; do ps -p "$pid" -o pid,ppid,comm,wchan >>"$prefix/process-debug.log" || true; done <"/sys/fs/cgroup$cgroup/cgroup.procs"
        fi
      fi
    fi
    sleep 0.1
  done
  return 1
}
wait_settled() {
  local end=$((SECONDS + 90))
  while (( SECONDS < end )); do
    inspect "$1"
    if jq -e '.state.cursor==3 and .actual.phase=="AttemptCommitted"' "$prefix/status-$1.json" >/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
verify() { "$prototype" verify "$config" "$prefix" "$1" "$2" >"$prefix/verify-$1.log" 2>&1; }
prepare duplicate slow
start_worker duplicate
wait_ready duplicate
"$prototype" duplicate "$config" "$prefix" duplicate
wait_settled duplicate
"$prototype" worker "$config" "$prefix" duplicate
verify duplicate success
echo 'PASS duplicate original requests and delivery retain one real launch and receipt'
prepare worker-restart slow
start_worker worker-restart
wait_ready worker-restart
systemctl kill --kill-whom=main --signal=KILL "$task-worker-restart.service"
wait_settled worker-restart
systemctl restart "$task-worker-restart.service"
verify worker-restart success
echo 'PASS SIGKILL of the accepted worker preserves the original invocation and independent acknowledgement'
prepare supervisor-restart slow
start_worker supervisor-restart
wait_ready supervisor-restart
listener=$(stat -c %i "$prefix/rpc/supervisor.sock")
systemctl kill --kill-whom=main --signal=KILL "$service"
wait_settled supervisor-restart
[[ $(stat -c %i "$prefix/rpc/supervisor.sock") == "$listener" ]]
verify supervisor-restart success
echo 'PASS supervisor SIGKILL recovers original facts through the same manager-owned listener'
prepare cancellation orphan
start_worker cancellation
wait_ready cancellation
files=$(jq -r .files "$prefix/status-cancellation.json")
for _ in {1..100}; do [[ -f "$files/src/orphan" ]] && break; sleep 0.05; done
before=$(wc -c <"$files/src/orphan")
sleep 0.3
[[ $(wc -c <"$files/src/orphan") -gt "$before" ]]
"$prototype" cancel "$config" "$prefix" cancellation
wait_settled cancellation
verify cancellation cancelled
before=$(wc -c <"$files/src/orphan")
sleep 0.3
[[ $(wc -c <"$files/src/orphan") == "$before" ]]
echo 'PASS root cancellation settles a detached SIGTERM-ignoring descendant before releasing its actual'
prepare completion-recovery slow
start_worker completion-recovery
wait_ready completion-recovery
directory=$(jq -r .directory "$prefix/status-completion-recovery.json")
systemctl stop "$socket" "$service"
for _ in {1..400}; do [[ -f "$directory/complete.json" ]] && break; sleep 0.1; done
[[ -f "$directory/complete.json" ]]
inspect completion-recovery
jq -e '.process.receipt==null' "$prefix/status-completion-recovery.json" >/dev/null
systemctl start "$socket" "$service"
wait_settled completion-recovery
verify completion-recovery success
echo 'PASS completion retained while intake is offline recovers before any replacement launch'
prepare denials denials
start_worker denials
wait_settled denials
verify denials success
files=$(jq -r .files "$prefix/status-denials.json")
[[ -f "$files/src/denials-ok" ]]
echo 'PASS native payload denies host, sibling, metadata, network, mount, inherited-descriptor and privilege access'
prepare capture-loss slow
start_worker capture-loss
wait_ready capture-loss
capture=$(jq -r .capture "$prefix/status-capture-loss.json")
systemctl kill --kill-whom=main --signal=KILL "$capture"
for _ in {1..100}; do inspect capture-loss; jq -e '.process.phase=="ProcessUnresolved"' "$prefix/status-capture-loss.json" >/dev/null && break; sleep 0.1; done
systemctl kill --kill-whom=main --signal=KILL "$task-capture-loss.service"
verify capture-loss unresolved
echo 'PASS lost output remains unresolved with its original capacity and file barrier retained'
prepare authority-denial complete
: >"$prefix/deny-authority"
start_worker authority-denial
wait_settled authority-denial
verify authority-denial refused
rm "$prefix/deny-authority"
echo 'PASS denied fresh exact authority records a proven refusal without a repository launch'
echo 'Workspace Linux prototype passed (10 cases); local Git, handoff and full IR-11 qualification remain open.'
