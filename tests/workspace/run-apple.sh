#!/usr/bin/env bash
# Preferred runtime qualification: native arm64 payload/guard in a disposable
# Apple guest. FRIC-21 permits the configured builder for the Haskell controller.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=${1:---prototype}
[[ "$mode" == --prototype || "$mode" == --provision || "$mode" == --git || "$mode" == --workflow || "$mode" == --workflow-only || "$mode" == --workspace-gates || "$mode" == --qualify || "$mode" == --continuing-only || "$mode" == --handoff-only || "$mode" == --ownership-only || "$mode" == --adaptive-only || "$mode" == --adaptive-transfer-only || "$mode" == --adaptive-live-only ]] || { echo 'Usage: run-apple.sh MODE [RUNTIME] [STAGED_LIVE_CONFIG]'; exit 64; }
live_config=${3:-}
if [[ "$mode" == --adaptive-live-only ]]; then
  [[ $# == 3 && -d "$live_config" ]] || { echo 'REFUSED: live mode needs explicitly staged private configuration'; exit 64; }
fi
taskdir=$(mktemp -d /tmp/shikigami-workspace-run.XXXXXX)
chmod 700 "$taskdir"
if [[ $# -ge 2 ]]; then runtime=$2; else
  nix build .#packages.x86_64-linux.shikigami-workspace-prototype --max-jobs 0 --cores 2 --no-link --no-write-lock-file --print-build-logs --json >"$taskdir/runtime.json" 2>"$taskdir/build.log"
  runtime=$(python3 - "$taskdir/runtime.json" <<'PY'
import json,sys
values=json.load(open(sys.argv[1]))
assert len(values)==1
print(values[0]['outputs']['out'])
PY
)
fi
[[ "$runtime" =~ ^/nix/store/[a-z0-9]{32}-[a-zA-Z0-9._+-]+$ ]] || { echo 'Invalid runtime output'; exit 64; }
name="shikigami-workspace-run-$(date -u +%Y%m%d%H%M%S)-$$"
printf '%s\n' "$name" >"$taskdir/container"
created=false
cleanup() {
  result=$?
  trap - EXIT
  if "$created"; then
    prefix=$(container exec "$name" cat /run/shikigami-workspace-prototype.prefix 2>/dev/null || true)
    if [[ "$prefix" =~ ^/var/lib/shikigami-prototype-[a-zA-Z0-9]+$ ]]; then
      mkdir -m 700 "$taskdir/evidence"
      container exec "$name" /bin/bash -c '
        cd "$1"
        files=()
        for name in live-native-controls.log adaptive-live-roots.json adaptive-live-assignment-state.json adaptive-live-call-state.json adaptive-live-dispatches.jsonl live-preflight.log adaptive-live-admission.json adaptive-live-authority.jsonl adaptive-live-selections.json adaptive-live-messages.json adaptive-live-replay.json adaptive-artifacts adaptive-archive.log adaptive-first-selections.json adaptive-selections.json; do [[ ! -e "$name" ]] || files+=("$name"); done
        for name in adaptive-completion-hold.json adaptive-alias-policy.json adaptive-target-refusal.json adaptive-root-race.json adaptive-unknown-crash.log adaptive-unknown-crashed.json adaptive-unknown-observe.log adaptive-unknown-observed.json adaptive-objectives.jsonl adaptive-ownership-crash.log adaptive-ownership-crashed.json adaptive-authorized-control.json adaptive-authorized-control.log adaptive-denied-control.log adaptive-restored-control.json adaptive-restored-control.log adaptive-outcome.log adaptive-outcome.json adaptive-result.log adaptive-result.json adaptive-followup.log adaptive-followup.json adaptive-admit.log adaptive-crash.log adaptive-drive.log adaptive-replay.log adaptive-first-evidence.json adaptive-recovery.json adaptive-evidence.json adaptive-seeds.json adaptive-provider-calls provision.log diagnostics.log process-debug.log clock-events.log clock-service.log clock-barrier.log http-status.log authority.log oauth.log supervisor.log migrations.log nix-tool.log nix-guard.log nix-postgres.log postgres-version.log pg-init.log pg-start.log workflow-admit.log workflow-edit.log workflow-run.log workflow-verify.log workflow-evidence.json workflow-model-calls integration.log integration-evidence.json integration-process-evidence.json continuing-followup.log continuing-followup-evidence.json continuing-prepare.log continuing-freeze.log continuing-settled.log continuing-late.log continuing-evidence.json continuing-status.json continuing-worker.log continuing-ownership.log continuing-ownership.json continuing-successor.log continuing-successor.json continuing-successor-fence.json public-metadata.jsonl continuing-diagnostics.jsonl; do [[ ! -f "$name" ]] || files+=("$name"); done
        for case_name in duplicate worker-restart supervisor-restart cancellation completion-recovery denials capture-loss authority-denial git-upgrade git-recovery git-denial; do
          for kind in prepare worker inspect verify advance git-worker duplicate; do name="$kind-$case_name.log"; [[ ! -f "$name" ]] || files+=("$name"); done
          name="status-$case_name.json"; [[ ! -f "$name" ]] || files+=("$name")
          if [[ -f "$name" ]]; then
            workspace=$(jq -r .files "$name")
            if [[ "$workspace" =~ ^/var/lib/shikigami-prototype-[a-zA-Z0-9]+/workspaces/[a-f0-9]{64}/files$ && ! -L "$workspace/src" && ! -L "$workspace/src/clock-evidence" && -f "$workspace/src/clock-evidence" ]]; then
              head -c 8192 "$workspace/src/clock-evidence" >"payload-clock-$case_name.log"
              files+=("payload-clock-$case_name.log")
            fi
          fi
        done
        tar -cf - "${files[@]}"
      ' fixture "$prefix" | tar -xf - -C "$taskdir/evidence" || { if [[ $result == 0 ]]; then result=1; fi; }
    fi
    container stop --time 5 "$name" >/dev/null || { if [[ $result == 0 ]]; then result=1; fi; }
  fi
  rm -f "$taskdir/key" "$taskdir/key.pub" "$taskdir/known_hosts"
  printf 'Private fixture evidence: %s\n' "$taskdir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 124' TERM INT
port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0))
    print(listener.getsockname()[1])
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$taskdir/key"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
container run --rm --detach --name "$name" --arch arm64 --rosetta --cpus 4 --memory 8G --cap-add ALL -p "127.0.0.1:$port:22" "$image" /sbin/init >/dev/null
created=true
container exec --interactive "$name" /usr/bin/timeout 300 /bin/bash -s <<'GUEST'
set -euo pipefail
guest_ready=false
for _ in {1..200}; do
  if systemctl start local-fs.target 2>/dev/null; then guest_ready=true; break; fi
  sleep 0.1
done
"$guest_ready"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends dbus gcc libc6-dev nix-bin sudo ca-certificates postgresql libpq-dev git jq python3 openssh-server >/dev/null 2>&1
install -d -m 700 /root/.ssh /var/lib/shikigami-workspace-fixture-code
install -d -m 755 /etc/nix
getent group nixbld >/dev/null || groupadd --system nixbld
for index in {1..4}; do useradd --system --gid nixbld --groups nixbld --home-dir /var/empty --no-create-home --shell /usr/sbin/nologin "nixbld-fixture$index"; done
cat >/etc/nix/nix.conf <<'NIX'
experimental-features = nix-command flakes
build-users-group = nixbld
max-jobs = 2
cores = 2
sandbox = true
NIX
cat >/etc/ssh/sshd_config.d/99-workspace-fixture.conf <<'SSH'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowUsers root
SSH
systemctl daemon-reload
systemctl start dbus ssh
: >/run/shikigami-workspace-prototype.disposable
: >/run/shikigami-workspace-prototype.clock-steps
GUEST
container exec --interactive "$name" /bin/sh -c 'cat >/root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' <"$taskdir/key.pub"
hostkey=$(container exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub)
printf '[127.0.0.1]:%s %s\n' "$port" "$hostkey" >"$taskdir/known_hosts"
export NIX_SSHOPTS="-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$taskdir/known_hosts"
target="ssh-ng://root@127.0.0.1:$port?ssh-key=$taskdir/key"
nix copy --no-check-sigs --to "$target" "$runtime" >"$taskdir/copy.log" 2>&1
# Copy only explicit fixture sources; no host directories or credentials mount.
tar --exclude='__pycache__' -cf - tests/workspace/run-linux.sh tests/workspace/fixture-oauth.py tests/workspace/prototype-payload.c tests/adaptive-delivery nix/workspace-deadline.nix shikigami-workers/cbits/workspace-deadline.c schema/Agent.dhall agents/triage-note.dhall agents/skills/triage-note | container exec --interactive "$name" tar -xf - -C /var/lib/shikigami-workspace-fixture-code
if [[ "$mode" == --adaptive-live-only ]]; then
  container exec "$name" install -d -m 700 /run/shikigami-live-config
  tar -C "$live_config" -cf - application.json limits.json | container exec --interactive "$name" tar -xf - -C /run/shikigami-live-config
fi
container exec "$name" /usr/bin/timeout 1800 /bin/bash /var/lib/shikigami-workspace-fixture-code/tests/workspace/run-linux.sh "$mode" "$runtime"
