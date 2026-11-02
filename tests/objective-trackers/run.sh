#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
arguments=()
if [ -n "${SHIKIGAMI_CABAL_PROJECT:-}" ]; then arguments+=("--project-file=$SHIKIGAMI_CABAL_PROJECT"); fi
cabal "${arguments[@]}" build exe:shikigami-server exe:shikigami-worker exe:shikigami-migrate exe:shikigami -j2
binaries=()
for executable in shikigami-server shikigami-worker shikigami-migrate shikigami; do
  binaries+=("$(cabal "${arguments[@]}" list-bin -v0 "exe:$executable")")
done
bash tests/objective-trackers/with-rei.sh -- python3 "$PWD/tests/objective-trackers/qualify.py" "$PWD" "${binaries[@]}"

# The shared native checkpoint provider is tested against the same import owner;
# this qualification does not claim real repository containment.
provider_log="$(mktemp "${TMPDIR:-/tmp}/shikigami-tracker-provider.XXXXXX")"
trap 'rm -f "$provider_log"' EXIT
cabal "${arguments[@]}" test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1 -p ObjectiveTracker' -j2 | tee "$provider_log"
python3 - "$provider_log" <<'PY_CHECK'
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_text()
assert "imported instructions invalidate the real worker checkpoint version:" in output
assert "All 0 tests passed" not in output
PY_CHECK
