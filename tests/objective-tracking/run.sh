#!/usr/bin/env bash
set -euo pipefail
umask 077
# This gate remains independent even when the caller normally enables trackers.
export SHIKIGAMI_OBJECTIVE_TRACKERS='{"enabled":"TrackersDisabled","connections":[],"pollSeconds":60,"batchSize":20,"reconciliationOperators":[]}'

for command in cabal createdb curl initdb pg_ctl psql python3; do
  command -v "$command" >/dev/null || { echo "objective qualification: missing $command" >&2; exit 1; }
done
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/shikigami-objectives.XXXXXX")"
pg_data="$work_dir/postgres"
pg_socket="$work_dir/socket"
authority_pid=""
oauth_pid=""
model_pid=""
cleanup() {
  status=$?
  trap - EXIT INT TERM
  for process in "$authority_pid" "$oauth_pid" "$model_pid"; do
    if [ -n "$process" ]; then kill "$process" 2>/dev/null || true; wait "$process" 2>/dev/null || true; fi
  done
  if [ -d "$pg_data" ]; then pg_ctl -D "$pg_data" stop -m fast >/dev/null 2>&1 || true; fi
  if [ "$status" -ne 0 ]; then
    for log in "$work_dir/"*.log; do
      [ ! -f "$log" ] || { echo "--- $(basename "$log") ---" >&2; tail -60 "$log" >&2; }
    done
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

project_cabal() {
  local arguments=()
  if [ -n "${SHIKIGAMI_CABAL_PROJECT:-}" ]; then arguments+=("--project-file=$SHIKIGAMI_CABAL_PROJECT"); fi
  (cd "$repo_root"; command cabal "${arguments[@]}" "$@")
}
project_cabal build exe:shikigami-migrate exe:shikigami-server exe:shikigami-worker exe:shikigami exe:shikigami-objective-fixture
for executable in shikigami-migrate shikigami-server shikigami-worker shikigami shikigami-objective-fixture; do
  project_cabal list-bin "exe:$executable" >"$work_dir/$executable.path"
done

mkdir -p "$pg_socket" "$work_dir/runtime/fixtures/qualification"
cp -R "$repo_root/schema" "$work_dir/runtime/schema"
cp -R "$repo_root/fixtures/qualification/objectives" "$work_dir/runtime/fixtures/qualification/objectives"
initdb --auth=trust --no-locale --encoding=UTF8 -D "$pg_data" >/dev/null
python3 - "$work_dir" <<'PY_PORTS'
import json, socket, sys
from pathlib import Path
listeners = []
for _ in range(6):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listeners.append(listener)
ports = dict(zip(["postgres", "http", "health", "authority", "oauth", "model"], [s.getsockname()[1] for s in listeners]))
(Path(sys.argv[1]) / "ports.json").write_text(json.dumps(ports))
PY_PORTS
port() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$work_dir/ports.json" "$1"; }
pg_port="$(port postgres)"
pg_ctl -D "$pg_data" -l "$work_dir/postgres.log" -o "-k $pg_socket -p $pg_port -h ''" start -w >/dev/null
createdb -h "$pg_socket" -p "$pg_port" shikigami
connection="host=$pg_socket port=$pg_port dbname=shikigami user=$(id -un)"
migrate_bin="$(cat "$work_dir/shikigami-migrate.path")"
DATABASE_URL="$connection" "$migrate_bin" up >"$work_dir/migrations.log" 2>&1

fixture_bin="$(cat "$work_dir/shikigami-objective-fixture.path")"
"$fixture_bin" authority "$work_dir" "$(port authority)" >"$work_dir/authority.log" 2>&1 &
authority_pid=$!
python3 "$repo_root/tests/objective-tracking/fixture-oauth.py" "$(port oauth)" "$(port authority)" "$work_dir/oauth-status.log" >"$work_dir/oauth.log" 2>&1 &
oauth_pid=$!
python3 "$repo_root/tests/objective-tracking/model.py" "$(port model)" "$work_dir/model-observations.jsonl" >"$work_dir/model.log" 2>&1 &
model_pid=$!
for _ in $(seq 1 100); do [ ! -f "$work_dir/issuer-public.txt" ] || break; sleep 0.1; done
test -f "$work_dir/issuer-public.txt"
python3 "$repo_root/tests/objective-tracking/continuity.py" "$repo_root" "$work_dir" "$connection"

# The provider fixture uses real session/objective stores and explicitly
# deterministic fence evidence. It does not qualify repository containment.
if ! project_cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1 -p /Objective/' >"$work_dir/provider-qualification.log" 2>&1; then
  cat "$work_dir/provider-qualification.log" >&2
  exit 1
fi
python3 - "$work_dir/provider-qualification.log" <<'PY_PROVIDERS'
from pathlib import Path
import sys
log = Path(sys.argv[1]).read_text()
assert "All " in log and " tests passed" in log
assert "integrated acceptance waits for a real unacknowledged tool receipt" in log
assert "sibling" in log and "instruction" in log
assert "retained trusted fence changes one owner" in log
assert "terminal objectives reconcile authentic accepted results" in log
print("PASS provider receipt recovery, sibling ordering, instruction-only invalidation, ownership continuity and late facts (deterministic fence fixture)")
print("PASS live unknown-attempt acceptance barrier and exact retry after retained source settlement")
PY_PROVIDERS
echo "PASS no-Rei objective continuity; workspace fencing and adaptive/recurring orchestration remain separate qualification"
