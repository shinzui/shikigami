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
