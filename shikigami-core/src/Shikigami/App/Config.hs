-- | The single process-level configuration composition point.
--
-- Every Shikigami executable — the HTTP server, each worker role, the
-- administrative commands, the migration runner — resolves its settings through
-- one typed value built here, rather than reading the environment where it
-- happens to need a value. This module exists so that ownership of that
-- composition point is settled at a package boundary before any feature plan
-- adds a setting.
--
-- The real surface is owned by
-- @docs\/plans\/37-adopt-settei-configuration-across-shikigami-binaries.md@: stable
-- keys, typed strict records, explicit environment bindings, source precedence,
-- redaction of secrets, startup diagnostics, and exit semantics all arrive with
-- that plan. Until then 'AppConfig' carries no fields, and no module in this
-- repository may call @getEnv@ or @lookupEnv@ to invent its own precedence
-- rules; existing call sites are inventoried by plan 37 and migrated there.
--
-- Two rules already bind anything added here. Secrets are credential references
-- or redacted secret types, and never gain a 'Show', JSON, or logging rendering
-- that would print their plaintext. Standard OpenTelemetry environment
-- variables (@OTEL_*@) stay owned by the OpenTelemetry SDK and are not
-- re-declared as Shikigami settings.
module Shikigami.App.Config
  ( AppConfig (..),
    emptyAppConfig,
  )
where

-- | The process-level application configuration.
--
-- Deliberately empty: plan 37 adds the first fields (database connection,
-- agents directory, downstream base URLs, provider selection) together with the
-- Settei declarations that resolve them. Constructing it today is free, so
-- composition roots can already thread a single configuration value without
-- being rewritten when the fields appear.
data AppConfig = AppConfig
  deriving stock (Eq, Show)

-- | The only 'AppConfig' there can be until plan 37 gives it fields.
emptyAppConfig :: AppConfig
emptyAppConfig = AppConfig
