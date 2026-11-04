#!/usr/bin/env bash
# Destructive fixture work is confined to a disposable guest explicitly marked
# by its provisioner. This runner never enables production process admission.
set -eEuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
mode=${1:-}
runtime=${2:-}
[[ $# == 2 && ( "$mode" == --prototype || "$mode" == --provision || "$mode" == --git || "$mode" == --workflow || "$mode" == --workflow-only || "$mode" == --workspace-gates || "$mode" == --qualify || "$mode" == --continuing-only || "$mode" == --handoff-only || "$mode" == --ownership-only || "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only ) && "$runtime" == /nix/store/* ]] || { echo 'Usage: run-linux.sh MODE RUNTIME'; exit 64; }
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
pg_bindir=
pg_started=false
cases=(duplicate worker-restart supervisor-restart cancellation completion-recovery denials capture-loss authority-denial)
if [[ "$mode" == --git || "$mode" == --workflow || "$mode" == --workspace-gates || "$mode" == --qualify ]]; then cases+=(git-upgrade git-recovery git-denial); fi
cleanup() {
  status=$?
  trap - EXIT ERR
  if [[ "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only ]] && "$pg_started"; then
    if /usr/bin/psql "$connection" -Atc "SELECT COALESCE(jsonb_agg(binding ORDER BY resource),'[]'::jsonb) FROM shikigami.workspace_bindings WHERE binding->>'repository' IN ('mori://fixture/adaptive-producer','mori://fixture/adaptive-consumer')" >"$prefix/adaptive-bindings.json" &&
      python3 -I "$repo/tests/adaptive-delivery/archive.py" --prefix "$prefix" >"$prefix/adaptive-archive.log" 2>&1; then
      :
    elif [[ "$status" == 0 ]]; then
      status=1
    fi
  fi
  systemctl kill --kill-whom=all --signal=CONT "$service" >/dev/null 2>&1 || true
  systemctl stop "$socket" "$service" "$authority" "$oauth" >/dev/null 2>&1 || true
  systemctl stop "$task-continuing.service" >/dev/null 2>&1 || true
  for boundary in outcome result followup; do
    systemctl kill --kill-whom=all --signal=CONT "$task-adaptive-$boundary.service" >/dev/null 2>&1 || true
    systemctl stop "$task-adaptive-$boundary.service" >/dev/null 2>&1 || true
  done
  if [[ -f "$prefix/continuing-status.json" ]]; then
    for key in '.process.unit' '.capture'; do
      unit=$(jq -r "$key // empty" "$prefix/continuing-status.json")
      if [[ "$unit" =~ ^shikigami-(workspace|capture)-[0-9a-f]{64}\.service$ ]]; then
        systemctl kill --kill-whom=main --signal=CONT "$unit" >/dev/null 2>&1 || true
        systemctl stop "$unit" >/dev/null 2>&1 || true
      fi
    done
  fi
  for case_name in "${cases[@]}"; do
    systemctl stop "$task-$case_name.service" >/dev/null 2>&1 || true
    systemctl stop "$task-$case_name-git.service" >/dev/null 2>&1 || true
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
  journalctl -u systemd-timesyncd.service -n 10 --output=short-monotonic --no-pager >"$prefix/clock-events.log" 2>&1 || true
  systemctl show systemd-timesyncd.service --property=ActiveState,StatusText >"$prefix/clock-service.log" 2>&1 || true
  if "$pg_started"; then
    /usr/bin/psql "$connection" -Atc "SELECT jsonb_build_object('kind','objective','objectiveId',objective_id,'revision',state->'revision','status',state->'status') FROM shikigami.objectives UNION ALL SELECT jsonb_build_object('kind','objective-receipt','objectiveId',objective_id,'operationKey',operation_key,'outcome',outcome) FROM shikigami.objective_receipts LIMIT 128" >"$prefix/adaptive-objectives.jsonl" 2>/dev/null || true
    /usr/bin/psql "$connection" -Atc "SELECT (SELECT count(*) FROM shikigami.workspace_bindings), (SELECT count(*) FROM shikigami.workspace_bindings WHERE state='ready'), (SELECT count(*) FROM shikigami.workspace_process_profiles), (SELECT count(*) FROM shikigami.workspace_process_profiles WHERE ready)" >"$prefix/diagnostics.log" 2>&1 || true
    /usr/bin/psql "$connection" -Atc "SELECT jsonb_build_object('kind','execution','data',to_jsonb(e)) FROM shikigami.executions e WHERE binding->>'rootId' IN (SELECT binding->>'rootId' FROM shikigami.worker_sessions) UNION ALL SELECT jsonb_build_object('kind','session','data',to_jsonb(s)) FROM shikigami.worker_sessions s UNION ALL SELECT jsonb_build_object('kind','message','data',to_jsonb(m)) FROM shikigami.worker_session_messages m UNION ALL SELECT jsonb_build_object('kind','admission','data',to_jsonb(a)) FROM shikigami.workspace_successor_admissions a UNION ALL SELECT jsonb_build_object('kind','control','data',to_jsonb(c)) FROM shikigami.workspace_controls c UNION ALL SELECT jsonb_build_object('kind','operation','data',to_jsonb(o)) FROM shikigami.execution_transcript_operations o JOIN shikigami.executions e USING(execution_id) WHERE e.binding->>'rootId' IN (SELECT binding->>'rootId' FROM shikigami.worker_sessions)" >"$prefix/continuing-diagnostics.jsonl" 2>/dev/null || true
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
# Allocation now uses PostgreSQL 18's native uuidv7(), as do host tests and the
# frozen runtime. Materialize that existing pinned package for the guest's
# native architecture instead of selecting the image's older apt server.
postgres_reference='github:NixOS/nixpkgs/d5dfd8e6716dde34398bc14bc87c10dece9c8c68#postgresql_18'
nix --extra-experimental-features 'nix-command flakes' build --json --no-link --no-write-lock-file "$postgres_reference" >"$prefix/nix-postgres.json" 2>"$prefix/nix-postgres.log"
postgres=$(python3 - "$prefix/nix-postgres.json" <<'POSTGRES'
import json,sys
values=json.load(open(sys.argv[1])); assert len(values)==1
print(values[0]['outputs']['out'])
POSTGRES
)
pg_bindir="$postgres/bin"
"$pg_bindir/postgres" --version >"$prefix/postgres-version.log"
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
if [[ "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only ]]; then
  cc -static -Wall -Wextra -Werror -O2 -o "$prefix/root/bin/adaptive-check" "$repo/tests/adaptive-delivery/validate.c"
  chmod 555 "$prefix/root/bin/adaptive-check"
fi
image_digest=$( { printf '%s\n' "$tool" "$guard"; sha256sum "$prefix/root/bin/probe"; if [[ "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only ]]; then sha256sum "$prefix/root/bin/adaptive-check"; fi; } | sha256sum | cut -d ' ' -f1)
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
python3 - "$prefix" "$connection" "$authority_port" "$runtime" "$guard" "$image_digest" "$oauth_port" "$repo" <<'PY'
import json,sys
from pathlib import Path
prefix,connection,port,runtime,guard,digest,oauth_port,repo=sys.argv[1:]
p=Path(prefix)
(p/'directory.json').write_text(json.dumps([{'principal_id':'agent_01h000000000000000'+name,'handle':name,'lifecycle':'active','display_name':'Workspace fixture'} for name in ['triage','coordinator','successor','producer','producer-review','consumer','consumer-review','consumer-successor']]))
config={'database':{'connection_string':connection},'directory':{'mode':'file','file':{'path':str(p/'directory.json')},'refresh_interval_seconds':1},'workspace':{'supervisor':{'socketPath':str(p/'rpc/supervisor.sock'),'users':[0],'workers':4,'timeoutSeconds':5}},'authorization':{'actions':{'mode':'kikan','kikan_en':{'base_url':f'http://127.0.0.1:{oauth_port}'},'shomei':{'base_url':f'http://127.0.0.1:{oauth_port}','client_id':'fixture'},'en':{'issuer_public_keys':(p/'issuer-public.txt').read_text(),'schema_hashes':'workspace-fixture-schema'},'caller_id':'workspace-fixture'}},'credentials':{'authorization':{'actions':{'shomei':{'client_secret':'fixture-secret'}}}}}
config['agents']={'directory':str(Path(repo)/'agents')}
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
if [[ "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only ]]; then
  adaptive_suffix=
  if [[ "$mode" == --adaptive-transfer-only ]]; then adaptive_suffix=-transfer; fi
  adaptive() { "$prototype" adaptive "$config" "$prefix" "$1$adaptive_suffix"; }
  python3 -I "$repo/tests/adaptive-delivery/prepare.py" --directory "$prefix/adaptive-repositories" >"$prefix/adaptive-seeds.json"
  adaptive admit >"$prefix/adaptive-admit.log" 2>&1
  if adaptive crash >"$prefix/adaptive-crash.log" 2>&1; then
    crash_status=0
  else
    crash_status=$?
  fi
  [[ "$crash_status" == 86 && -f "$prefix/adaptive-crashed" ]]
  # Observe committed owner records, then kill the entire controller cgroup.
  # Workspace payload units belong to the independent supervisor and survive.
  # These probes never write a journal, mailbox or operation projection.
  adaptive_restart_after() {
    local boundary=$1 query=$2 unit="$task-adaptive-$1.service"
    local end=$((SECONDS + 180)) observed=false
    systemd-run --quiet --unit="$unit" -p Type=exec -p Restart=no -p RemainAfterExit=yes -p KillMode=control-group -p UMask=0077 -p "StandardOutput=file:$prefix/adaptive-$boundary.log" -p "StandardError=file:$prefix/adaptive-$boundary.log" -- "$prototype" adaptive "$config" "$prefix" "drive$adaptive_suffix"
    while (( SECONDS < end )); do
      /usr/bin/psql "$connection" -Atc "$query" >"$prefix/adaptive-$boundary.json"
      if jq -e 'length>0' "$prefix/adaptive-$boundary.json" >/dev/null; then
        [[ $(systemctl show "$unit" --property=ActiveState --value) == active ]]
        systemctl kill --kill-whom=all --signal=STOP "$unit"
        # Recheck with the controller stopped: the result probe must precede
        # its consumer's integration, rather than merely win a polling race.
        /usr/bin/psql "$connection" -Atc "$query" >"$prefix/adaptive-$boundary.json"
        if ! jq -e 'length>0' "$prefix/adaptive-$boundary.json" >/dev/null; then
          systemctl kill --kill-whom=all --signal=CONT "$unit"
          continue
        fi
        systemctl kill --kill-whom=all --signal=KILL "$unit"
        for _ in {1..100}; do
          [[ $(systemctl show "$unit" --property=ExecMainStatus --value) != 9 ]] || break
          sleep 0.1
        done
        [[ $(systemctl show "$unit" --property=ExecMainCode --value) == 2 && $(systemctl show "$unit" --property=ExecMainStatus --value) == 9 ]]
        observed=true
        break
      fi
      [[ $(systemctl show "$unit" --property=ActiveState --value) != failed ]]
      sleep 0.1
    done
    "$observed"
  }
  if [[ "$mode" == --adaptive-transfer-only ]]; then
    if adaptive unknown-crash >"$prefix/adaptive-unknown-crash.log" 2>&1; then
      unknown_status=0
    else
      unknown_status=$?
    fi
    [[ "$unknown_status" == 92 && -f "$prefix/adaptive-unknown-crashed.json" ]]
    adaptive unknown-observe >"$prefix/adaptive-unknown-observe.log" 2>&1
    systemctl kill --kill-whom=all --signal=CONT "$service"
  fi
  adaptive_restart_after outcome "SELECT jsonb_agg(jsonb_build_object('operationId',operation_id,'executionId',execution_id,'fingerprint',state->'fingerprint','outcome',state->'outcome') ORDER BY operation_id) FROM shikigami.execution_transcript_operations WHERE execution_id IN (SELECT execution_id FROM shikigami.executions WHERE binding->>'rootId' IN (SELECT binding->>'rootId' FROM shikigami.worker_sessions)) AND state->'specification'->>'kind'='ToolOperation' AND state->'outcome' IS NOT NULL AND state->'outcome'<>'null'::jsonb"
  adaptive_restart_after result "SELECT jsonb_agg(jsonb_build_object('sessionId',r.session_id,'assignmentId',r.assignment_id,'receipt',r.state,'consumedCursor',s.state->'consumedCursor') ORDER BY r.assignment_id) FROM shikigami.worker_session_results r JOIN shikigami.worker_sessions s USING(session_id) WHERE (s.state->>'consumedCursor')::bigint < (r.state->>'cursor')::bigint"
  if [[ "$mode" == --adaptive-transfer-only ]]; then
    if adaptive ownership-crash >"$prefix/adaptive-ownership-crash.log" 2>&1; then
      ownership_status=0
    else
      ownership_status=$?
    fi
    [[ "$ownership_status" == 91 && -f "$prefix/adaptive-ownership-crashed.json" ]]
  fi
  adaptive_restart_after followup "SELECT jsonb_agg(jsonb_build_object('sessionId',session_id,'assignmentId',assignment_id,'operationId',operation_id,'sequence',sequence) ORDER BY assignment_id) FROM shikigami.worker_session_messages WHERE sequence>0"
  adaptive drive >"$prefix/adaptive-drive.log" 2>&1
  cat "$prefix/adaptive-admit.log" "$prefix/adaptive-drive.log"
  jq -e '(.format==1 or .format==2) and .status=="Completed" and (.integrated.repositories | length)==2' "$prefix/adaptive-evidence.json" >/dev/null
  cp "$prefix/adaptive-evidence.json" "$prefix/adaptive-first-evidence.json"
  cp "$prefix/adaptive-provider-calls" "$prefix/adaptive-first-provider-calls"
  probe_session=$(/usr/bin/psql "$connection" -Atc "SELECT session_id FROM shikigami.worker_sessions WHERE (state->>'consumedCursor')::bigint=(state->>'eventCursor')::bigint ORDER BY session_id LIMIT 1")
  [[ -n "$probe_session" ]]
  "$runtime/bin/shikigami" --config "$config" workers integrate "$probe_session" --operation adaptive-authority-check >"$prefix/adaptive-authorized-control.json" 2>"$prefix/adaptive-authorized-control.log"
  printf 'deny\n' >"$prefix/deny-authority"
  if "$runtime/bin/shikigami" --config "$config" workers integrate "$probe_session" --operation adaptive-authority-check >"$prefix/adaptive-denied-control.log" 2>&1; then
    echo 'FAIL revoked authority allowed a protected accepted-session command'
    exit 1
  else
    denial_status=$?
  fi
  [[ "$denial_status" == 1 ]]
  rm -f "$prefix/deny-authority"
  "$runtime/bin/shikigami" --config "$config" workers integrate "$probe_session" --operation adaptive-authority-check >"$prefix/adaptive-restored-control.json" 2>"$prefix/adaptive-restored-control.log"
  adaptive drive >"$prefix/adaptive-replay.log" 2>&1
  python3 - "$prefix" <<'REPLAY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1])
first=json.loads((p/'adaptive-first-evidence.json').read_text())
replayed=json.loads((p/'adaptive-evidence.json').read_text())
before=(p/'adaptive-first-provider-calls').read_bytes()
after=(p/'adaptive-provider-calls').read_bytes()
authorized=json.loads((p/'adaptive-authorized-control.json').read_text())
restored=json.loads((p/'adaptive-restored-control.json').read_text())
assert authorized==restored, 'restored authorization changed the accepted control response'
assert first==replayed, 'terminal replay changed accepted evidence or root usage'
assert before==after, 'terminal replay repeated provider work'
assert (p/'adaptive-crashed').read_text()=='1\n'
(p/'adaptive-recovery.json').write_text(json.dumps({
    'format':1,
    'adaptation_commit_restart':{'exitCode':86,'markerObserved':True},
    'committed_boundary_restarts':{name:{'signal':9,'controllerStoppedBeforeSnapshot':True,'records':json.loads((p/f'adaptive-{name}.json').read_text())}
                                    for name in ['outcome','result','followup']},
    'action_denial':{'exitCode':1,'authorized':authorized,'restored':restored,'noProviderCalls':True},
    'ownership_commit_restart':({'exitCode':91,'markerObserved':True} if first['format']==2 else None),
    'unknown_effect_restart':({'exitCode':92,'markerObserved':True} if first['format']==2 else None),
    'terminal_replay':{'sameEvidence':True,'providerCallsBefore':hashlib.sha256(before).hexdigest(),
                       'providerCallsAfter':hashlib.sha256(after).hexdigest()}
},indent=2)+'\n')
REPLAY
  echo 'Native adaptive two-repository qualification passed; live trial and the complete coupled fault matrix remain separate gates.'
  exit 0
fi
prepare() {
  if [[ -f /run/shikigami-workspace-prototype.clock-steps ]]; then
    /usr/bin/timeout 40 "$prefix/root/bin/probe" --await-clock-step >>"$prefix/clock-barrier.log"
  fi
  "$prototype" prepare "$config" "$prefix" "$1" "$2" >"$prefix/prepare-$1.log" 2>&1
}
prepare_upgrade() {
  if [[ -f /run/shikigami-workspace-prototype.clock-steps ]]; then
    /usr/bin/timeout 40 "$prefix/root/bin/probe" --await-clock-step >>"$prefix/clock-barrier.log"
  fi
  "$prototype" prepare-upgrade "$config" "$prefix" "$1" >"$prefix/prepare-$1.log" 2>&1
  start_worker "$1"
  wait_settled "$1"
  "$prototype" advance-upgrade "$config" "$prefix" "$1" >"$prefix/advance-$1.log" 2>&1
}
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
wait_git_settled() {
  local end=$((SECONDS + 90))
  while (( SECONDS < end )); do
    inspect "$1"
    if jq -e '.state.cursor==4 and .actual.phase=="AttemptCommitted"' "$prefix/status-$1.json" >/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
start_git_worker() {
  systemd-run --quiet --unit="$task-$1-git.service" -p Type=exec -p Restart=no -p RemainAfterExit=yes -p UMask=0077 -p StandardOutput=null -p "StandardError=file:$prefix/git-worker-$1.log" -- "$prototype" "$2" "$config" "$prefix" "$1"
}
verify_git() { "$prototype" verify-git "$config" "$prefix" "$1" "$2" >"$prefix/verify-$1.log" 2>&1; }
verify() { "$prototype" verify "$config" "$prefix" "$1" "$2" >"$prefix/verify-$1.log" 2>&1; }
release_command() {
  files=$(jq -r .files "$prefix/status-$1.json")
  python3 - "$files/src/release-command" <<'RELEASE'
import os,sys
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
os.close(fd)
RELEASE
}
# A payload's readiness marker can precede release of the supervisor's
# admission lock. Repeat only the same original coordinates after a bounded
# unresolved response; this never prepares or launches a replacement attempt.
duplicate_original() {
  for turn in {1..3}; do
    if "$prototype" duplicate "$config" "$prefix" "$1" >"$prefix/duplicate-$1.log" 2>&1; then return 0; fi
    sleep 0.25
  done
  return 1
}
if [[ "$mode" != --workflow-only && "$mode" != --continuing-only && "$mode" != --handoff-only && "$mode" != --ownership-only ]]; then
prepare duplicate slow
start_worker duplicate
wait_ready duplicate
duplicate_original duplicate
release_command duplicate
wait_settled duplicate
"$prototype" worker "$config" "$prefix" duplicate
verify duplicate success
echo 'PASS duplicate original requests and delivery retain one real launch and receipt'
prepare worker-restart slow
start_worker worker-restart
wait_ready worker-restart
systemctl kill --kill-whom=main --signal=KILL "$task-worker-restart.service"
release_command worker-restart
wait_settled worker-restart
systemctl restart "$task-worker-restart.service"
verify worker-restart success
echo 'PASS SIGKILL of the accepted worker preserves the original invocation and independent acknowledgement'
prepare supervisor-restart slow
start_worker supervisor-restart
wait_ready supervisor-restart
listener=$(stat -c %i "$prefix/rpc/supervisor.sock")
systemctl kill --kill-whom=main --signal=KILL "$service"
release_command supervisor-restart
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
release_command completion-recovery
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
if [[ "$mode" != --git && "$mode" != --workflow && "$mode" != --workspace-gates && "$mode" != --qualify ]]; then
  echo 'Workspace Linux prototype passed (10 cases); local Git, handoff and full IR-11 qualification remain open.'
  exit 0
fi
prepare_upgrade git-upgrade
start_git_worker git-upgrade worker
wait_git_settled git-upgrade
"$prototype" worker "$config" "$prefix" git-upgrade
verify_git git-upgrade applied
echo 'PASS accepted native edit and validation produce one exact local commit, including after duplicate delivery'
prepare_upgrade git-recovery
# Direct Git execution needs no intake RPC. Leave the independent factual scan
# offline until publication has happened and the committing worker is dead.
systemctl stop "$socket" "$service"
start_git_worker git-recovery worker-git-crash
for _ in {1..300}; do [[ -f "$prefix/git-published-git-recovery" ]] && break; sleep 0.1; done
[[ -f "$prefix/git-published-git-recovery" ]]
systemctl kill --kill-whom=main --signal=KILL "$task-git-recovery-git.service"
"$prototype" freeze "$config" "$prefix" git-recovery
: >"$prefix/deny-authority"
systemctl start "$socket" "$service"
wait_git_settled git-recovery
verify_git git-recovery applied
rm "$prefix/deny-authority"
echo 'PASS independent Git receipt recovery settles the original actual after worker SIGKILL, ownership freeze and fresh-authority denial'
prepare_upgrade git-denial
start_git_worker git-denial worker-git-deny
wait_git_settled git-denial
verify_git git-denial refused
rm "$prefix/deny-authority"
echo 'PASS fresh publication denial after tree capture refuses the retained candidate without changing HEAD'
echo 'Workspace Linux process and local Git prototype passed (13 cases); production workflow, handoff and full IR-11 qualification remain open.'

fi

if [[ "$mode" == --workflow || "$mode" == --workflow-only || "$mode" == --workspace-gates || "$mode" == --qualify ]]; then
  rm -f "$prefix/deny-authority"
  "$prototype" workflow "$config" "$prefix" admit >"$prefix/workflow-admit.log" 2>&1
  "$prototype" workflow "$config" "$prefix" edit >"$prefix/workflow-edit.log" 2>&1
  if [[ -f /run/shikigami-workspace-prototype.clock-steps ]]; then
    /usr/bin/timeout 40 "$prefix/root/bin/probe" --await-clock-step >>"$prefix/clock-barrier.log"
  fi
  "$prototype" workflow "$config" "$prefix" run >"$prefix/workflow-run.log" 2>&1
  "$prototype" workflow "$config" "$prefix" verify >"$prefix/workflow-verify.log" 2>&1
  echo 'PASS configured durable parent/child upgrades, validates and commits once across worker restart and parent redelivery'
  if [[ "$mode" == --workflow-only ]]; then
    echo 'Focused configured durable workflow qualification passed (3 cases including native provisioning); the process/Git matrix is separate.'
  else
    echo 'Workspace configured durable workflow qualification passed (14 cases); handoff and full IR-11 qualification remain open.'
  fi
fi

if [[ "$mode" == --workspace-gates || "$mode" == --qualify || "$mode" == --continuing-only || "$mode" == --handoff-only || "$mode" == --ownership-only ]]; then
  if [[ "$mode" != --continuing-only && "$mode" != --handoff-only && "$mode" != --ownership-only ]]; then
  "$prototype" integration "$config" "$prefix" >"$prefix/integration.log" 2>&1
  cat "$prefix/integration.log"
  /usr/bin/psql "$connection" -Atc "SELECT jsonb_agg(jsonb_build_object('repository',b.binding->'repository','base',b.binding->'base','process',p.record) ORDER BY p.operation_id) FROM shikigami.workspace_processes p JOIN shikigami.workspace_bindings b USING(resource) WHERE b.binding->'request'->>'rootId'=(SELECT binding->'request'->>'rootId' FROM shikigami.workspace_bindings WHERE binding->'request'->>'runId'='integration-worker-one')" >"$prefix/integration-process-evidence.json"
  jq -e 'length==6 and ([.[] | select(.process.receipt.termination=="ProcessExited" and .process.receipt.exitCode==0)] | length)==5 and ([.[] | select(.process.receipt.termination=="ProcessExited" and .process.receipt.exitCode==77)] | length)==1' "$prefix/integration-process-evidence.json" >/dev/null
  fi
  if [[ "$mode" != --handoff-only && "$mode" != --ownership-only ]]; then
  "$prototype" continuing "$config" "$prefix" followup >"$prefix/continuing-followup.log" 2>&1
  cat "$prefix/continuing-followup.log"
  /usr/bin/psql "$connection" -Atc "SELECT jsonb_agg(jsonb_build_object('workspace',b.binding->'workspace','repository',b.binding->'repository','base',b.binding->'base','original',b.binding->'request','followup',jsonb_build_object('runId',a.run_id,'assignmentId',a.admission->'assignmentId','workspace',a.admission->'workspace','owner',a.admission->'owner','epoch',a.admission->'epoch'),'profile',jsonb_build_object('ready',p.ready,'userId',p.user_id,'bindingDigest',p.profile->'bindingDigest','instructionDigest',p.profile->'instructionDigest'),'cleanup',c.plan,'complete',c.complete)) FROM shikigami.workspace_bindings b LEFT JOIN shikigami.workspace_successor_admissions a USING(resource) LEFT JOIN shikigami.workspace_process_profiles p USING(resource) LEFT JOIN shikigami.workspace_cleanup c USING(resource) WHERE b.binding->'request'->>'rootId' IN (SELECT binding->>'rootId' FROM shikigami.worker_sessions WHERE binding->'scope'->>'parent'='native-followup')" >"$prefix/continuing-followup-evidence.json"
  jq -e 'length==1 and (.[0] | .complete==true and .profile.ready==true and .followup.runId!=.original.runId and .followup.workspace==.workspace and .cleanup.ownership.runId==.followup.runId)' "$prefix/continuing-followup-evidence.json" >/dev/null
  fi
  "$prototype" continuing "$config" "$prefix" prepare >"$prefix/continuing-prepare.log" 2>&1
  if [[ -f /run/shikigami-workspace-prototype.clock-steps ]]; then
    /usr/bin/timeout 40 "$prefix/root/bin/probe" --await-clock-step >>"$prefix/clock-barrier.log"
  fi
  systemd-run --quiet --unit="$task-continuing.service" -p Type=exec -p Restart=no -p RemainAfterExit=yes -p UMask=0077 -p StandardOutput=null -p "StandardError=file:$prefix/continuing-worker.log" -- "$prototype" continuing "$config" "$prefix" worker
  continuing_inspect() { "$prototype" continuing "$config" "$prefix" inspect; }
  for _ in {1..200}; do
    continuing_inspect
    files=$(jq -r .files "$prefix/continuing-status.json")
    [[ -f "$files/src/orphan" ]] && break
    sleep 0.1
  done
  [[ -f "$files/src/orphan" ]]
  capture=$(jq -r .capture "$prefix/continuing-status.json")
  [[ "$capture" =~ ^shikigami-capture-[0-9a-f]{64}\.service$ ]]
  systemctl kill --kill-whom=main --signal=STOP "$capture"
  "$prototype" continuing "$config" "$prefix" freeze >"$prefix/continuing-freeze.log" 2>&1
  cat "$prefix/continuing-freeze.log"
  # A busy shared lock is also unresolved. Require the retained freeze before
  # revoking authority, retrying the same production RPC and immutable intent.
  python3 - "$prefix" "$connection" <<'FROZEN'
import json,re,socket,struct,subprocess,sys,time
from pathlib import Path
root=Path(sys.argv[1]); intent=json.loads((root/'continuing-intent.json').read_text())
resource=intent['workspace']['resource']; assert re.fullmatch('[a-f0-9]{64}',resource)
query="SELECT EXISTS(SELECT 1 FROM shikigami.workspace_controls WHERE resource='"+resource+"' AND frozen)"
def exact(peer,size):
    value=b''
    while len(value)<size:
        chunk=peer.recv(size-len(value)); assert chunk; value+=chunk
    return value
for attempt in range(30):
    frozen=subprocess.check_output(['/usr/bin/psql',sys.argv[2],'-Atc',query]).strip()
    if frozen==b't': break
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as peer:
        peer.settimeout(5); peer.connect(str(root/'rpc/supervisor.sock'))
        _,uid,_=struct.unpack('3i',peer.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12)); assert uid==0
        body=json.dumps({'format':2,'action':'fence','intent':intent},separators=(',',':')).encode(); assert 0<len(body)<=4096
        peer.sendall(struct.pack('!I',len(body))+body)
        size=struct.unpack('!I',exact(peer,4))[0]; assert 0<size<=8192
        reply=json.loads(exact(peer,size)); assert reply.get('format')==2 and 'fence' in reply
        assert 'FencedAndSettled' not in json.dumps(reply)
    time.sleep(.1)
else: raise RuntimeError('workspace admission freeze was not retained')
FROZEN
  listener=$(stat -c '%d:%i' "$prefix/rpc/supervisor.sock")
  systemctl kill --kill-whom=main --signal=KILL "$task-continuing.service" || true
  systemctl kill --kill-whom=main --signal=KILL "$service"
  touch "$prefix/deny-authority"
  python3 - "$prefix/directory.json" paused <<'LIFECYCLE'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); rows=json.loads(path.read_text())
for row in rows:
    if row['principal_id']=='agent_01h000000000000000triage': row['lifecycle']=sys.argv[2]
staged=path.with_suffix('.next'); staged.write_text(json.dumps(rows)); staged.replace(path)
LIFECYCLE
  systemctl kill --kill-whom=main --signal=CONT "$capture"
  systemctl start "$service"
  [[ $(stat -c '%d:%i' "$prefix/rpc/supervisor.sock") == "$listener" ]]
  settled=false
  for _ in {1..200}; do
    continuing_inspect
    if jq -e '.process.phase=="ProcessSettled" and (.actual.phase=="AttemptCommitted" or .actual.lateReceipt!=null)' "$prefix/continuing-status.json" >/dev/null; then settled=true; break; fi
    sleep 0.2
  done
  "$settled"
  "$prototype" continuing "$config" "$prefix" settled >"$prefix/continuing-settled.log" 2>&1
  cat "$prefix/continuing-settled.log"
  rm "$prefix/deny-authority"
  python3 - "$prefix/directory.json" <<'LIFECYCLE'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); rows=json.loads(path.read_text())
for row in rows: row['lifecycle']='active'
staged=path.with_suffix('.next'); staged.write_text(json.dumps(rows)); staged.replace(path)
LIFECYCLE
  sleep 2
  "$prototype" continuing "$config" "$prefix" late >"$prefix/continuing-late.log" 2>&1
  cat "$prefix/continuing-late.log"
  if [[ "$mode" == --qualify || "$mode" == --ownership-only ]]; then
    "$prototype" continuing "$config" "$prefix" ownership >"$prefix/continuing-ownership.log" 2>&1
    cat "$prefix/continuing-ownership.log"
    # Restart the independent provider and use a new controller process after
    # the objective commit but before the session acknowledges its receipt.
    listener=$(stat -c '%d:%i' "$prefix/rpc/supervisor.sock")
    systemctl kill --kill-whom=main --signal=KILL "$service"
    systemctl start "$service"
    [[ $(stat -c '%d:%i' "$prefix/rpc/supervisor.sock") == "$listener" ]]
    if [[ -f /run/shikigami-workspace-prototype.clock-steps ]]; then
      /usr/bin/timeout 40 "$prefix/root/bin/probe" --await-clock-step >>"$prefix/clock-barrier.log"
    fi
    "$prototype" continuing "$config" "$prefix" successor >"$prefix/continuing-successor.log" 2>&1
    cat "$prefix/continuing-successor.log"
    python3 - "$prefix" "$connection" <<'SUCCESSOR_FENCE'
import json,socket,struct,subprocess,sys,time
from pathlib import Path
root=Path(sys.argv[1]); intent=json.loads((root/'continuing-intent.json').read_text())
operator_replies=[json.loads(line) for line in (root/'continuing-successor.log').read_text().splitlines() if line.startswith('{')]
assert len(operator_replies)==2, 'expected original and duplicate administrative recovery replies'
expected={'tag':'HandoffEstablished','contents':[intent['newOwner'],intent['newEpoch']]}
assert all(reply=={'tag':'TransferObserved','contents':expected} for reply in operator_replies), 'the administrative command itself must establish the real handoff'
successor=json.loads((root/'continuing-successor.json').read_text())
successor['operatorReplies']=operator_replies
(root/'continuing-successor.json').write_text(json.dumps(successor))
def exact(peer,size):
    value=b''
    while len(value)<size:
        chunk=peer.recv(size-len(value)); assert chunk; value+=chunk
    return value
def admitted(owner,epoch):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as peer:
        peer.settimeout(5); peer.connect(str(root/'rpc/supervisor.sock'))
        _,uid,_=struct.unpack('3i',peer.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12)); assert uid==0
        body=json.dumps({'format':2,'action':'admitWrite','workspace':intent['workspace'],'sessionId':intent['sessionId'],'owner':owner,'epoch':epoch,'operationId':intent['operationId']},separators=(',',':')).encode(); assert 0<len(body)<=4096
        peer.sendall(struct.pack('!I',len(body))+body)
        size=struct.unpack('!I',exact(peer,4))[0]; assert 0<size<=8192
        reply=json.loads(exact(peer,size)); assert reply.get('format')==2 and type(reply.get('admitted')) is bool
        return reply['admitted']
new=False
for _ in range(30):
    new=admitted(intent['newOwner'],intent['newEpoch'])
    if new: break
    time.sleep(.1)
old=admitted(intent['oldOwner'],intent['oldEpoch'])
assert old is False and new is True
(root/'continuing-successor-fence.json').write_text(json.dumps({'oldOwnerAdmitted':old,'successorAdmitted':new,'oldEpoch':intent['oldEpoch'],'successorEpoch':intent['newEpoch']}))
ownership=json.loads((root/'continuing-ownership.json').read_text())
receipts=json.loads(subprocess.check_output(['/usr/bin/psql',sys.argv[2],'-Atc',"SELECT jsonb_agg(jsonb_build_object('objectiveId',objective_id,'operationId',operation_key,'fingerprint',fingerprint,'outcome',outcome)) FROM shikigami.objective_receipts WHERE operation_key LIKE 'objective-handoff:%'"],text=True))
assert len(receipts)==1 and receipts[0]['objectiveId']==ownership['objective']
ownership['commandReceipt']=receipts[0]
ownership['establishedFence']={'oldOwnerAdmitted':old,'successorAdmitted':new,'oldEpoch':intent['oldEpoch'],'successorEpoch':intent['newEpoch']}
(root/'continuing-ownership.json').write_text(json.dumps(ownership))
print('PASS established successor authority refuses the former owner at the live workspace write boundary')
SUCCESSOR_FENCE
  fi
  /usr/bin/psql "$connection" -Atc "SELECT to_jsonb(e) FROM shikigami.executions e UNION ALL SELECT to_jsonb(o) FROM shikigami.execution_transcript_operations o UNION ALL SELECT result FROM keiro.keiro_workflow_steps" >"$prefix/public-metadata.jsonl"
  python3 - "$prefix" <<'PRIVACY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
markers=[b'fixture-host-secret',b'fixture-sibling-secret',b'workspace-fixture-token',b'fixture-secret',b'new dependency',b'Fixture policy: validate the exact resulting tree.']
files=[root/'public-metadata.jsonl',*root.glob('*.log')]
assert (root/'public-metadata.jsonl').stat().st_size > 0
for path in files:
    body=path.read_bytes()
    assert not any(marker in body for marker in markers), 'public fixture metadata/log privacy check failed'
print('PASS retained workflow/operation metadata and public logs exclude fixture contents, credentials and bearer authority')
PRIVACY
  if [[ "$mode" == --ownership-only ]]; then
    echo 'Focused real ownership and successor gates passed (9 cases); full qualification remains separate.'
  elif [[ "$mode" == --handoff-only ]]; then
    echo 'Focused workspace fence gates passed (6 cases); successor and full matrix gates remain separate.'
  elif [[ "$mode" == --continuing-only ]]; then
    echo 'Focused continuing workspace gates passed (7 cases); the full matrix remains separate.'
  else
    echo 'Workspace-owned native gates passed (22 cases).'
  fi

  if [[ "$mode" == --qualify || "$mode" == --ownership-only ]]; then
    if [[ "$mode" == --qualify ]]; then echo 'Full governed workspace qualification passed (25 cases), including real objective ownership and accepted successor writes across restart.'; fi
  fi
fi
