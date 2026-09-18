#!/usr/bin/env bash
set -euo pipefail

for command in cabal createdb curl hurl initdb pg_ctl python3; do
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
  if [ -d "$pg_data" ]; then
    pg_ctl -D "$pg_data" stop -m fast >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    [ ! -f "$pg_log" ] || { echo "--- postgres log ---" >&2; cat "$pg_log" >&2; }
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
cabal build exe:shikigami-migrate exe:shikigami-server
migrate_bin="$(cabal list-bin exe:shikigami-migrate)"
server_bin="$(cabal list-bin exe:shikigami-server)"
connection="host=$pg_socket port=$pg_port dbname=shikigami user=$(id -un)"
DATABASE_URL="$connection" "$migrate_bin" up

http_port="$(free_port)"
PG_CONNECTION_STRING="$connection" \
  "$server_bin" --host 127.0.0.1 --port "$http_port" >"$server_log" 2>&1 &
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

hurl --test --variable "base_url=$base_url" tests/hurl/*.hurl
