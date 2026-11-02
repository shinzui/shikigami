#!/usr/bin/env bash
# Real provider qualification. Source: mori://shinzui/rei (fixture source URIs
# pending), pinned to the same public commit as the production typed client.
set -euo pipefail

if [[ "${1:-}" != -- || $# -lt 2 ]]; then
  echo 'usage: bash tests/objective-trackers/with-rei.sh -- COMMAND [ARGS...]' >&2
  exit 2
fi
shift
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rei_source="$(mori path mori://shinzui/rei)"
rei_commit=c109222db550537ec998ecc6fc1866cc7a35e29a
if [[ "$(git -C "$rei_source" rev-parse HEAD)" != "$rei_commit" ]] || [[ -n "$(git -C "$rei_source" status --porcelain --untracked-files=no)" ]]; then
  echo 'Rei fixture requires the clean pinned source at mori://shinzui/rei; refusing another source tuple' >&2
  exit 1
fi

# The real server has native dependencies beyond Shikigami's client closure
# (including liblzma for its documentation assets). Use its declared dev shell.
if [[ "${SHIKIGAMI_REI_FIXTURE_SHELL:-}" != "$rei_commit" ]]; then
  # Shell hooks install repository-local development hooks in the working
  # directory, so enter the owning checkout before activating its shell.
  cd "$rei_source"
  exec nix develop . --no-write-lock-file -c env SHIKIGAMI_REI_FIXTURE_SHELL="$rei_commit" bash "$task_root/tests/objective-trackers/with-rei.sh" -- "$@"
fi

# Upstream's fixture owns fresh-schema construction, projection workers, fake
# Mori, loopback reservation, scrubbed service identity and bracketed cleanup.
# Only this test component depends on Rei Core/server; production links neither.
fixture_dir="$task_root/.dev/objective-trackers/rei-fixture"
mkdir -p "$fixture_dir"
python3 - "$task_root" "$rei_source" "$fixture_dir" <<'PY'
import pathlib, re, sys
root, rei, target = map(pathlib.Path, sys.argv[1:])
source = (rei / 'rei-api/rei-api.cabal').read_text()
component = source.split('test-suite rei-api-live-test\n', 1)[1].split('\ntest-suite ', 1)[0]
dependencies = component.split('  build-depends:\n', 1)[1].split('\n--', 1)[0].strip()
modules = ['Rei.Api.TestSupport.' + name for name in ['DatabaseFixtures', 'LiveFixture', 'LiveSchema', 'MoriFixture']]
(target / 'fixture.cabal').write_text('''cabal-version: 3.4
name: shikigami-rei-fixture
version: 0.0.0.0
build-type: Simple
executable shikigami-rei-fixture
  main-is: Main.hs
  default-language: GHC2024
  default-extensions: DeriveAnyClass DuplicateRecordFields MultilineStrings OverloadedLabels OverloadedStrings
  ghc-options: -threaded -rtsopts -with-rtsopts=-N2
  hs-source-dirs:
    ''' + str(root / 'tests/objective-trackers/fixture') + '\n    ' + str(rei / 'rei-api/test-live') + '\n  other-modules:\n    ' + '\n    '.join(modules) + '\n  build-depends:\n    ' + dependencies + '\n')
project = []
section = None
for line in (rei / 'cabal.project').read_text().splitlines():
    if line and not line[0].isspace() and not line.startswith('--'):
        section = line.split(':', 1)[0] if ':' in line else None
    if line.startswith('import: '):
        location = line[len('import: '):]
        line = 'import: ' + (location if '://' in location else str(rei / location))
    elif section in ['packages', 'optional-packages'] and line.startswith('  ') and not line.lstrip().startswith('--'):
        line = '  ' + str(rei / line.strip())
    project.append(line)
    if line == 'packages:':
        project.append('  ' + str(target / 'fixture.cabal'))
(target / 'cabal.project').write_text('\n'.join(project) + '\n')
PY

unset REI_PG_CONNECTION_STRING PG_CONNECTION_STRING MORI_API_URL REI_API_TOKENS REI_HURL_TOKEN REI_HURL_FIXTURE HURL_BASE_URL
cabal build --project-file="$fixture_dir/cabal.project" --builddir="$fixture_dir/dist" -j2 rei-api:exe:rei-api shikigami-rei-fixture:exe:shikigami-rei-fixture
server_bin="$(cabal list-bin -v0 --project-file="$fixture_dir/cabal.project" --builddir="$fixture_dir/dist" rei-api:exe:rei-api)"
fixture_bin="$(cabal list-bin -v0 --project-file="$fixture_dir/cabal.project" --builddir="$fixture_dir/dist" shikigami-rei-fixture:exe:shikigami-rei-fixture)"
export REI_API_BIN="$server_bin"
cd "$task_root"
exec "$rei_source/scripts/with-api-test-tools.sh" "$fixture_bin" "$@"
