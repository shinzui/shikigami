#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cabal build shikigami-objective-tracker-rei-test -fobjective-tracker-rei-tests -j2
test_bin="$(cabal list-bin -v0 shikigami-objective-tracker-rei-test -fobjective-tracker-rei-tests)"
exec bash tests/objective-trackers/with-rei.sh -- "$test_bin" --num-threads=1 "$@"
