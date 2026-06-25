{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Shikigami.Migrations
  ( shikigamiOwnMigrations,
    shikigamiMigrations,
    runShikigamiMigrations,
    runShikigamiMigrationsNoCheck,
  )
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.List (sortOn)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Kioku.Migrations (kiokuMigrations)
import Streaming.Prelude qualified as Streaming

-- | Parse shikigami's OWN embedded SQL files (currently just shikigami_fired).
shikigamiOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shikigamiOwnMigrations =
  traverse parseEmbeddedMigration embeddedFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
      let stream :: PureStream m
          stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
      result <- parseAddedSqlMigration name stream
      case result of
        Left err -> fail ("Invalid shikigami migration " <> name <> ": " <> err)
        Right migration -> pure migration

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
  runCoddLogger do
    migrations <- shikigamiMigrations
    applyMigrations settings (Just migrations) connectTimeout verifySchemas

runShikigamiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShikigamiMigrationsNoCheck settings connectTimeout =
  runCoddLogger do
    migrations <- shikigamiMigrations
    applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))

embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = sortOn fst $(embedDir "sql-migrations")
