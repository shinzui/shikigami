{-# LANGUAGE TemplateHaskell #-}

module Shikigami.Migrations
  ( shikigamiOwnMigrations,
    shikigamiMigrations,
    runShikigamiMigrations,
    runShikigamiMigrationsNoCheck,
  )
where

import Codd (ApplyResult, CoddSettings, VerifySchemas)
import Codd.Extras.Apply (applyParsedMigrations, applyParsedMigrationsNoCheck)
import Codd.Extras.Embedded qualified as Embedded
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.List (sortOn)
import Data.Time (DiffTime)
import Kioku.Migrations (kiokuMigrations)

-- | Parse shikigami's OWN embedded SQL files (currently just shikigami_fired).
shikigamiOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiOwnMigrations = Embedded.parseEmbeddedMigrations "Shikigami" embeddedFiles

-- | The full shikigami migration set. IMPORTANT: kiokuMigrations ALREADY composes
-- kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations (see
-- /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs), so we
-- must NOT prepend kiroku/keiro again or codd will reject the duplicate timestamps.
shikigamiMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiMigrations = do
  kioku <- kiokuMigrations
  own <- shikigamiOwnMigrations
  pure (kioku <> own)

runShikigamiMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runShikigamiMigrations settings connectTimeout verifySchemas =
  applyParsedMigrations settings connectTimeout verifySchemas shikigamiMigrations

runShikigamiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShikigamiMigrationsNoCheck settings connectTimeout =
  applyParsedMigrationsNoCheck settings connectTimeout shikigamiMigrations

-- Embeds sql-migrations/*.sql at compile time: shikigami_fired + the pgmq schema
-- (pgmq-schema.sql, applied via codd in lieu of the unbuildable pgmq-migration).
embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = sortOn fst $(embedDir "sql-migrations")
