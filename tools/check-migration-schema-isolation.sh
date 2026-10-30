#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sql_dir="$root/shikigami-migrations/sql-migrations"

failures=0

report_matches() {
  local description="$1"
  local pattern="$2"
  shift 2
  local output
  output="$(rg -n -i "$pattern" "$@" || true)"
  if [[ -n "$output" ]]; then
    printf 'migration-schema-isolation: %s\n%s\n' "$description" "$output" >&2
    failures=1
  fi
}

# All application SQL belongs to the first-release baseline and is qualified.
managed=("$sql_dir"/*.sql)

report_matches \
  'application-managed SQL mutates search_path or the current schema' \
  '\bSET[[:space:]]+(LOCAL[[:space:]]+|SESSION[[:space:]]+)?(search_path|SCHEMA)\b|set_config[[:space:]]*\([[:space:]]*['\''"]search_path['\''"]' \
  "${managed[@]}"

# Check the common object-bearing statements in application-owned SQL. CREATE
# INDEX names are intentionally allowed to be unqualified, but their ON target
# must be qualified. Temporary objects and dynamic SQL are not used here.
if ! python3 - "${managed[@]}" <<'PY'
import pathlib
import re
import sys

object_name = r'["a-z_]["a-z0-9_$]*(?:\.["a-z_]["a-z0-9_$]*)?'
patterns = [
    re.compile(rf"^\s*CREATE\s+(?:TABLE|VIEW|SEQUENCE|TYPE|FUNCTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?P<name>{object_name})", re.I | re.S),
    re.compile(rf"^\s*ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?P<name>{object_name})", re.I | re.S),
    re.compile(rf"^\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?P<name>{object_name})", re.I | re.S),
    re.compile(rf"^\s*CREATE\s+(?:UNIQUE\s+)?INDEX\b.*?\bON\s+(?P<name>{object_name})", re.I | re.S),
    re.compile(rf"\bREFERENCES\s+(?P<name>{object_name})", re.I | re.S),
]

bad = []
for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    text = path.read_text()
    without_comments = "\n".join(line.split("--", 1)[0] for line in text.splitlines())
    offset = 0
    for statement in without_comments.split(";"):
        line_number = without_comments.count("\n", 0, offset) + 1
        for pattern in patterns:
            for match in pattern.finditer(statement):
                if "." not in match.group("name"):
                    rendered = " ".join(statement.strip().split())
                    bad.append(f"{path}:{line_number}:{rendered[:240]}")
        offset += len(statement) + 1

if bad:
    print("migration-schema-isolation: application-managed SQL contains an unqualified object reference", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY
then
  failures=1
fi

if (( failures != 0 )); then
  exit 1
fi

echo "migration-schema-isolation: application SQL is schema-qualified; PGMQ is owned by pgmq-migration"
