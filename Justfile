# Create the dev database (idempotent) and apply the full schema.
# Relies on the PG* environment variables set by the nix devShell (flake.nix):
# PGHOST is a Unix-socket dir inside the repo, PGDATABASE=shikigami.
create-database:
    #!/usr/bin/env bash
    set -euo pipefail
    # Create the database only if it does not already exist (idempotent).
    if ! psql -h "$PGHOST" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'" | grep -q 1; then
      createdb -h "$PGHOST" "$PGDATABASE"
    fi
    just migrate

# Apply the full schema via the shikigami-migrate executable (pg-migrate). One
# pass applies the kiroku, keiro, kioku, and shikigami migration components in
# dependency order — no copied .sql files; each library embeds its own — and
# then reconciles keiro's read-model registry. pg-migrate records what it applied
# and skips it next time, so re-running is a no-op.
#
# The leading `touch` forces cabal to re-run the Template Haskell splice that
# embeds sql-migrations/*.sql into the binary. pg-migrate's recompile plugin
# already tracks the manifest, but touching the .cabal also covers a stale
# configure after a git pull, and costs one tiny recompile.
#
# libpq's connection-string parser needs a 'user' value; the trust-auth
# superuser role is the current OS user (initdb default).
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    touch shikigami-migrations/shikigami-migrations.cabal
    DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
      cabal run shikigami-migrate -- up

# Show what the migration plan would do without touching the database.
migrate-status:
    #!/usr/bin/env bash
    set -euo pipefail
    DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
      cabal run shikigami-migrate -- status

# Scaffold a new shikigami migration and append it to the manifest.
#
# pg-migrate orders migrations by their position in
# shikigami-migrations/sql-migrations/manifest, not by filename. The timestamped
# filename convention is nonetheless load-bearing once a migration has been
# applied: the durable migration identity is <component>/<filename without
# extension>, so renaming an applied file renames an applied migration. A new
# file follows the convention for consistency, and appending puts it last, which
# is what an additive migration wants.
#
# Both the manifest and every file it lists are compilation dependencies: a stray
# .sql file or a missing manifest entry fails the build rather than silently
# shipping an incomplete component.
# Usage: just new-migration add-foo
new-migration name="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{name}}" ]; then
      echo "usage: just new-migration name=<slug>   (slug: [a-z0-9-])" >&2
      exit 1
    fi
    if ! printf '%s' "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      echo "error: name must match [a-z0-9-] (got '{{name}}')" >&2
      exit 1
    fi
    ts="$(date -u '+%Y-%m-%d-%H-%M-%S')"
    file="${ts}-{{name}}.sql"
    dir="shikigami-migrations/sql-migrations"
    dest="${dir}/${file}"
    if [ -e "$dest" ]; then
      echo "error: $dest already exists" >&2
      exit 1
    fi
    cat > "$dest" <<EOF
    -- Migration: {{name}}
    -- Created: ${ts} UTC
    -- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

    -- Kizashi read-model tables live in the kiroku schema: the app queries them
    -- on the event-store pool, whose search_path is kiroku (kiroku-store
    -- defaultConnectionSettings: schema="kiroku", extraSearchPath=[]). Pin it so
    -- unqualified CREATEs land where the app resolves them.
    SET search_path TO kiroku, pg_catalog;
    EOF
    printf '%s\n' "$file" >> "${dir}/manifest"
    echo "Created $dest and appended it to ${dir}/manifest"

# ── The keiro-dsl specification gate ────────────────────────────────────────
#
# domain/shikigami.keiro-workspace is the checked source of truth for
# Shikigami's durable workflow identities. These recipes are the gate: run
# `just keiro-gate` before merging anything that touches domain/, the generated
# layer under shikigami-core/src/Shikigami/*/Generated/, or a durable identity.
#
# keiro-dsl is pinned to the cohort version by cabal.project (constraints +
# extra-packages), so `cabal run keiro-dsl` is the same toolchain for everyone
# and does not depend on PATH or on a keiro checkout.

# Check the composed workspace with the language floor, every warning denied,
# and both machine-readable reports.
#
# --min-language 5 fails any member whose *effective* version is below 5 with
# LanguageVersionBelowMinimum. --deny-warnings is the fleet standard
# (mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption): a keiro-dsl
# warning is a real finding, and a new one appearing on a toolchain upgrade is
# a finding about this specification, not a reason to pre-commit to ignoring
# it. --fail-on-opaque raises CoverageOpaqueGateExceeded as an error if a new
# opaque boundary appears on a persisted root.
keiro-check:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    cabal run -v0 keiro-dsl -- check domain/shikigami.keiro-workspace \
      --min-language 5 \
      --deny-warnings \
      --explain-bindings \
      --report-out build/keiro-check-report.json \
      --coverage-report build/keiro-coverage.json \
      --fail-on-opaque

# Assert that every member declares its language rather than inheriting one.
#
# This is part of the gate, not a convenience. A member that loses its preamble
# falls back to legacy version 1 *silently*, and composition then fails with
# WorkspaceLanguageVersionMismatch rather than naming the real cause. Asserting
# sourceForm == "declared" reports the real cause.
keiro-inspect:
    #!/usr/bin/env bash
    set -euo pipefail
    report="$(cabal run -v0 keiro-dsl -- inspect domain/shikigami.keiro-workspace --format=json)"
    printf '%s\n' "$report"
    fail() { echo "keiro-inspect: $1" >&2; exit 1; }
    printf '%s' "$report" | grep -q '"languageSupport":"stable"' \
      || fail "the effective contract is not stable"
    forms="$(printf '%s' "$report" | grep -o '"sourceForm":"[^"]*"' | sort -u)"
    [ "$forms" = '"sourceForm":"declared"' ] \
      || fail "a member does not declare its language version: $forms"
    versions="$(printf '%s' "$report" | grep -o '"effectiveLanguageVersion":[0-9]*' | sort -u)"
    [ "$versions" = '"effectiveLanguageVersion":5' ] \
      || fail "a member's effective language version is not 5: $versions"
    members="$(printf '%s' "$report" | grep -o '"sourceForm"' | wc -l | tr -d ' ')"
    [ "$members" -ge 1 ] || fail "the workspace reported no members"
    echo "keiro-inspect: $members member(s), all declared at language 5"

# Regenerate the generated layer, then prove the regeneration was a no-op.
#
# Determinism is the property that makes a committed generated file trustworthy:
# it is what the current specification produces, not what someone's editor left
# behind. `git diff --exit-code` after a scaffold is the whole test.
keiro-scaffold:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace \
      --out shikigami-core/src
    git diff --exit-code -- shikigami-core/src \
      || { echo "keiro-scaffold: the committed generated layer is out of date; commit the regeneration" >&2; exit 1; }

# Classify a proposed change to a durable contract across the six compatibility
# surfaces and exit non-zero on a gated BREAKING finding.
#
# `diff` reconstructs the old manifest *and* its old member set with `git show`,
# so it must run inside the repository. Pass a ref: `just keiro-diff HEAD^`, or
# the merge base with master for a branch.
keiro-diff since="HEAD^":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    cabal run -v0 keiro-dsl -- diff domain/shikigami.keiro-workspace \
      --since {{since}} \
      --explain \
      --report-out build/keiro-diff.json \
      --replay-impact-out build/keiro-replay-impact.json

# The whole gate, in the order a failure is cheapest to read.
keiro-gate since="HEAD^":
    #!/usr/bin/env bash
    set -euo pipefail
    just keiro-check
    just keiro-inspect
    just keiro-scaffold
    just keiro-diff {{since}}
    cabal test keiro-shikigami-conformance
