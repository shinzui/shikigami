#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# The Rei provider and its qualification live in the Kikan binding (plan 135, M4).
cabal build kikan-shikigami-binding:test:kikan-shikigami-binding-rei-test -fobjective-tracker-rei-tests -j2
test_bin="$(cabal list-bin -v0 kikan-shikigami-binding:test:kikan-shikigami-binding-rei-test -fobjective-tracker-rei-tests)"
exec bash tests/objective-trackers/with-rei.sh -- "$test_bin" --num-threads=1 "$@"
