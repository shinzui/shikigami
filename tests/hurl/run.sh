#!/usr/bin/env bash
set -euo pipefail

for command in cabal createdb curl hurl hurlfmt initdb pg_ctl python3; do
  command -v "$command" >/dev/null || {
    echo "tests/hurl/run.sh: missing required command: $command" >&2
    exit 1
  }
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/shikigami-hurl.XXXXXX")"
pg_data="$work_dir/postgres"
pg_socket="$work_dir/socket"
pg_log="$work_dir/postgres.log"
server_log="$work_dir/server.log"
server_pid=""
worker_pid=""
worker_log="$work_dir/worker.log"

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ -n "$worker_pid" ]; then
    kill "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
  if [ -d "$pg_data" ]; then
    pg_ctl -D "$pg_data" stop -m fast >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    [ ! -f "$pg_log" ] || { echo "--- postgres log ---" >&2; cat "$pg_log" >&2; }
    [ ! -f "$worker_log" ] || { echo "--- worker log ---" >&2; cat "$worker_log" >&2; }
    [ ! -f "$server_log" ] || { echo "--- server log ---" >&2; cat "$server_log" >&2; }
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

mkdir -p "$pg_socket"
initdb --auth=trust --no-locale --encoding=UTF8 -D "$pg_data" >/dev/null
pg_port="$(free_port)"
pg_ctl -D "$pg_data" -l "$pg_log" -o "-k $pg_socket -p $pg_port -h ''" start -w >/dev/null
createdb -h "$pg_socket" -p "$pg_port" shikigami

cd "$repo_root"
cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} build exe:shikigami-migrate exe:shikigami-server exe:shikigami-client exe:shikigami-worker exe:shikigami
migrate_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami-migrate)"
server_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami-server)"
connection="host=$pg_socket port=$pg_port dbname=shikigami user=$(id -un)"
DATABASE_URL="$connection" "$migrate_bin" up

token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
export SHIKIGAMI_API_TOKEN="$token"
http_port="$(free_port)"
PG_CONNECTION_STRING="$connection" \
  "$server_bin" --host 127.0.0.1 --port "$http_port" --set agents.directory=tests/hurl/agents --set http.auth.mode=bearer >"$server_log" 2>&1 &
server_pid=$!
base_url="http://127.0.0.1:$http_port"

for _ in $(seq 1 100); do
  if curl -fsS "$base_url/health/ready" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "tests/hurl/run.sh: server exited before becoming ready" >&2
    exit 1
  fi
  sleep 0.1
done
curl -fsS "$base_url/health/ready" >/dev/null

suite_dir="$repo_root/shikigami-api/test/hurl"
secrets_file="$work_dir/hurl-secrets.env"
printf 'token=%s\n' "$token" > "$secrets_file"
chmod 600 "$secrets_file"
hurlfmt --check "$suite_dir/"*.hurl
bash "$suite_dir/run.sh" "$base_url" "$secrets_file"
# The disposable fixture explicitly opts into perimeter and write scenarios.
hurl --test --variable "base_url=$base_url" --secrets-file "$secrets_file" "$suite_dir/auth.hurl" "$suite_dir/agent-runs.hurl"

client_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami-client)"
"$client_bin" --token "$token" agents show heartbeat --server "$base_url"
"$client_bin" agents list --server "$base_url" --first 1

"$client_bin" runs request heartbeat --key client-live --server "$base_url"
"$client_bin" runs request heartbeat --key client-live --server "$base_url"

# A real piped payload and a literal retry identify the same accepted work.
printf '{"input":"stdin-contract"}' | "$client_bin" runs request heartbeat --key client-stdin --stdin --server "$base_url"
printf 'invalid PRIVATE_STDIN_MUST_BE_IGNORED' | "$client_bin" runs request heartbeat --key client-stdin --payload '{"input":"stdin-contract"}' --server "$base_url" >"$work_dir/stdin-replay.txt"
python3 - "$work_dir/stdin-replay.txt" <<'PY_STDIN'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().startswith("replayed ")
PY_STDIN

# Before drain, the client can observe acceptance and distinguish timeout/errors.
live_request="$("$client_bin" runs request heartbeat --key client-live --server "$base_url")"
live_run_id="$(printf '%s\n' "$live_request" | awk 'NR == 1 { print $2 }')"
"$client_bin" runs show heartbeat "$live_run_id" --server "$base_url"
"$client_bin" runs list heartbeat --first 1 --server "$base_url"
operator_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami)"
PG_CONNECTION_STRING="$connection" "$operator_bin" runs show shikigami.agent-run "$live_run_id" --json >"$work_dir/operator-accepted.json"
python3 - "$work_dir/operator-accepted.json" <<'PY_ACCEPTED'
import json, sys
with open(sys.argv[1]) as stream:
    value = json.load(stream)
assert value["lifecycle"]["status"] == "accepted", value
assert value["workflow"] is None, value
PY_ACCEPTED
wait_status=0
"$client_bin" runs wait heartbeat "$live_run_id" --timeout 0 --server "$base_url" || wait_status=$?
[ "$wait_status" -eq 2 ]
wait_status=0
"$client_bin" runs wait heartbeat no-such-run --timeout 0 --server "$base_url" || wait_status=$?
[ "$wait_status" -eq 3 ]

# The fixture heartbeat has no external sinks; a real worker can complete it.
worker_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami-worker)"
PG_CONNECTION_STRING="$connection" "$worker_bin" --set agents.directory=tests/hurl/agents --set "health.port=$(free_port)" >"$worker_log" 2>&1 &
worker_pid=$!
"$client_bin" runs wait heartbeat "$live_run_id" --timeout 60 --interval 1 --server "$base_url"
"$client_bin" runs show heartbeat "$live_run_id" --server "$base_url"
operator_bin="$(cabal ${SHIKIGAMI_CABAL_PROJECT:+--project-file=$SHIKIGAMI_CABAL_PROJECT} list-bin exe:shikigami)"
PG_CONNECTION_STRING="$connection" "$operator_bin" runs show shikigami.agent-run "$live_run_id" --json >"$work_dir/operator-run.json"
python3 - "$work_dir/operator-run.json" <<'PY_CHECK'
import json, sys
with open(sys.argv[1]) as stream:
    value = json.load(stream)
assert value["lifecycle"]["status"] == "succeeded", value
assert value["lifecycle"]["failure"] is None, value
PY_CHECK

# Exercise a real permanent behavior failure and the client's terminal exit code.
kill "$worker_pid"
wait "$worker_pid"
worker_pid=""
mkdir -p "$work_dir/failing-agents"
python3 - "$repo_root" "$work_dir/failing-agents/heartbeat.dhall" <<'PY_FAILURE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
text = (root / "tests/hurl/agents/heartbeat.dhall").read_text()
text = text.replace("../../../schema/Agent.dhall", str(root / "schema/Agent.dhall"))
text = text.replace('task = "noop-summary"', 'task = "missing-task-for-http-status-test"')
Path(sys.argv[2]).write_text(text)
PY_FAILURE
failed_request="$("$client_bin" runs request heartbeat --key client-failure --server "$base_url")"
failed_run_id="$(printf '%s\n' "$failed_request" | awk 'NR == 1 { print $2 }')"
PG_CONNECTION_STRING="$connection" "$worker_bin" --set "agents.directory=$work_dir/failing-agents" --set "health.port=$(free_port)" >>"$worker_log" 2>&1 &
worker_pid=$!
wait_status=0
"$client_bin" runs wait heartbeat "$failed_run_id" --timeout 60 --interval 1 --server "$base_url" || wait_status=$?
[ "$wait_status" -eq 1 ]
"$client_bin" runs show heartbeat "$failed_run_id" --server "$base_url"

# The same process remains live through a dependency outage; only this task's
# database is stopped. No worker remains when its fixture database is removed.
kill "$worker_pid"
wait "$worker_pid"
worker_pid=""
pg_ctl -D "$pg_data" stop -m fast >/dev/null
hurl --test --max-time 30 --variable "base_url=$base_url" --secrets-file "$secrets_file" "$suite_dir/unavailable.hurl"
