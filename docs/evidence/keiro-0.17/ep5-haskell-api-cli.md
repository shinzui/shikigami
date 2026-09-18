# EP-5 Haskell, HTTP, CLI, and configuration evidence

This record closes the rows owned by EP-5 in the pattern-adoption matrix. The
audit used the `shinzui/haskell-jitsurei` corpus at
`fb6574d971da2bc3ae52bce279828577895ca5f6` and the configuration subset of
`shinzui/keiro-runtime-patterns` at
`c0d7f5cc4246689d15344b9f45b6e763e1cde886`.

## Haskell conventions

Every library, executable, and test stanza imports its package's `common`
stanza. Those stanzas select GHC2024 and the shared record extensions. The
hand-owned source audit found no prepositive qualified imports, implicit
deriving strategies, or type-prefixed record fields. It corrected the remaining
lazy data-record field and made each use of generic-lens labels import
`Data.Generics.Labels ()` locally. Newtype payloads retain their required
unannotated form, and Servant generic route records remain an intentional
strictness exception because their fields are type-level route declarations.
Generated Keiro modules remain generator-owned.

`Shikigami.Prelude` continues to own the small shared import vocabulary and
Aeson options without importing the generic-lens orphan. Existing multiline
SQL uses the repository's `MultilineStrings` convention. The core and wire
compatibility suites are the serialization guard for these source-only changes.

## HTTP and observability

The public API currently consists only of the typed liveness and readiness
routes from `servant-health`. `Shikigami.Api.Problem` and the server error
formatters already own one six-field RFC 9457 shape, including 404 and 405
framework failures while preserving the headers supplied by Servant. There is no public request-body,
capture, query, authentication, or collection route, so malformed body,
capture/query, unsupported-media, and Relay pagination behavior have no current
surface. Adding placeholder routes would create product API solely to exercise
a pattern.

`Shikigami.Api.OpenApi` derives the checked-in document from the same Servant
proxy and pins operation IDs and artifact drift. Telemetry wraps the real WAI
application, and request logs are one bounded JSON line with an allow-list of
fields and active-span correlation. The probe exclusion now consumes
`Servant.Health.Paths.healthRawPaths` rather than repeating wire paths.

`tests/hurl/run.sh` starts a disposable PostgreSQL instance, applies the real
migrations, starts the real server with local-only settings, waits for readiness,
runs the health and RFC 9457 fixtures, and cleans up both processes. It requires
no provider keys or external services.

## CLI and configuration

All long-running and one-off operational roles build parsers through
`withConfigOptions`. `Shikigami.App.Version` now gives those roles and the admin
CLI consistent offline `--version` output using `githash` locally and a
`GIT_HASH` fallback in Nix. The migration CLI retains its pg-migrate-owned
surface and dedicated `DATABASE_URL` boundary under ADR 0032. The lightweight
typed client retains its package boundary rather than depending on core solely
for presentation behavior.

The fallback was compiled from a Git-free indexed source snapshot with
`GIT_HASH=abcdef1`; the actual module rendered `shikigami v0.1.0.0 (abcdef1)`.
The repository's older default Nix package still points `callCabal2nix` at the
multi-package root and fails before Haskell compilation because no root Cabal
file exists. The flake now carries the required configure flag for that package
once its separate package-graph defect is repaired.

Optparse-applicative automatically adds Bash, Zsh, and Fish completion-script
generation to every parser executed through `execParser`; the executable smoke
checks exercise those generated scripts without configuration or resource
acquisition. Existing help is grouped through the Settei option groups and the
mounted Keiro operations tree. Settei already provides ordered file,
environment, named-option, and `--set` sources; schema, explanation, and
`--check-config` diagnostics stop before resource acquisition and redact
secrets.

Shikigami has no command-alias configuration, clipboard output, fzf selector,
help-topic registry, stdin payload contract, per-command agent subprocess
configuration, or Claude CLI subprocess. Those patterns are excluded until such
a product surface exists. The project also has no Kubernetes manifests;
process-compose owns local lifecycle, while runtime code already owns probe and
graceful-shutdown behavior.
