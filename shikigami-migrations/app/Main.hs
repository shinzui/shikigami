-- | @shikigami-migrate@: apply the database migrations.
--
-- == Why this executable does not use the shared configuration declaration
--
-- Every other Shikigami binary resolves its settings from
-- @Shikigami.App.Config@ in @shikigami-core@. This one cannot, and the reason is
-- structural rather than a matter of taste: @shikigami-core@'s test suite
-- depends on this package's public @test-support@ sublibrary (it needs a
-- migrated database), so adding @shikigami-core@ to this executable's
-- @build-depends@ makes the two packages mutually dependent. Cabal's solver
-- rejects that outright — it reports @rejecting: shikigami-core:*test (cyclic
-- dependencies)@ and refuses to build the project — because it detects cycles at
-- package rather than component granularity.
--
-- So this binary keeps codd's own @CODD_*@ environment contract, read by
-- @getCoddSettings@ below, in the same way
-- @shikigami-workers\/src\/Shikigami\/Telemetry.hs@ keeps the OpenTelemetry SDK's
-- @OTEL_*@ contract: an external library owns those names and parses them
-- itself. See @justfile@'s @migrate@ recipe for the variables a developer sets.
--
-- Unifying this surface belongs to
-- @docs\/plans\/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md@,
-- which owns the
-- migration components, manifests, CLI, and test support and can restructure the
-- package boundary while it does so.
module Main (main) where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shikigami.Migrations (runShikigamiMigrationsNoCheck)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runShikigamiMigrationsNoCheck settings (secondsToDiffTime 5)
  pure ()
