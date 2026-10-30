#!/usr/bin/env bash
set -euo pipefail

# This runner consumes an explicitly selected, already-running service. It never
# provisions state or discovers a target from ambient environment variables.
if [ "$#" -ne 2 ]; then
  echo "usage: bash run.sh BASE_URL SECRETS_FILE" >&2
  exit 2
fi
suite_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hurl --test --variable "base_url=$1" --secrets-file "$2" \
  "$suite_dir/health.hurl" \
  "$suite_dir/agents.hurl" \
  "$suite_dir/problems.hurl" \
  "$suite_dir/openapi.hurl"
