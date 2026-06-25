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

# Apply the full schema via the shikigami-migrate executable (codd). One pass
# installs BOTH the kiroku event-store schema (shikigami-migrate calls the kiroku
# migration library in-process — no copied .sql files) AND shikigami's own
# timestamped read-model migrations, in timestamp order, idempotently. codd
# records applied migrations and skips already-applied ones.
#
# The leading `touch` forces cabal to re-run the Template Haskell `embedDir`
# splice that bakes sql-migrations/*.sql into the binary. GHC only tracks files
# that existed at the last compile, so a BRAND-NEW migration file (just added by
# `just new-migration`, a git pull, etc.) is otherwise silently NOT embedded and
# would be skipped. Touching the .cabal triggers a reconfigure + recompile of
# the (tiny) migrations module so the binary always embeds the current file set.
#
# codd's libpq connection-string parser requires a 'user' value; the trust-auth
# superuser role is the current OS user (initdb default).
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    touch shikigami-migrations/shikigami-migrations.cabal
    CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=kiroku \
      cabal run shikigami-migrate

# Scaffold a new timestamped shikigami migration in the codd-required filename
# format (YYYY-MM-DD-HH-MM-SS-<name>.sql). codd identifies/orders migrations by
# this leading UTC timestamp, so names are always generated, never hand-written.
# The file is embedded into the binary at compile time; `just migrate` forces
# the re-embed, so just edit the generated file's body and run `just migrate`.
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
    dest="shikigami-migrations/sql-migrations/${ts}-{{name}}.sql"
    if [ -e "$dest" ]; then
      echo "error: $dest already exists" >&2
      exit 1
    fi
    cat > "$dest" <<EOF
    -- codd: in-txn

    -- Migration: {{name}}
    -- Created: ${ts} UTC
    -- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.

    -- Kizashi read-model tables live in the kiroku schema: the app queries them
    -- on the event-store pool, whose search_path is kiroku (kiroku-store
    -- defaultConnectionSettings: schema="kiroku", extraSearchPath=[]). Pin it so
    -- unqualified CREATEs land where the app resolves them.
    SET search_path TO kiroku, pg_catalog;
    EOF
    echo "Created $dest"
