module Shikigami.Server.Command.PublishFixture
  ( runPublishFixture,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.Trigger.Publish (publishEnvelope)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @publish-fixture <file> [--broker B --topic T]@: publish one Activity Envelope
-- from a JSON file onto the activity stream with the keiro-* headers.
--
-- The broker and topic come from the resolved configuration under @kafka.broker@
-- and @kafka.activity.topic@; the @--broker@ and @--topic@ flags are
-- command-line sources for those same keys.
runPublishFixture :: FilePath -> AppConfig -> IO ()
runPublishFixture path config = do
  decoded <- Aeson.eitherDecodeFileStrict' path
  case decoded :: Either String ActivityEnvelope of
    Left e -> do
      hPutStrLn stderr ("publish-fixture: cannot decode " <> path <> ": " <> e)
      exitFailure
    Right env -> do
      r <- publishEnvelope ((.kafkaBroker) config) topic env
      case r of
        Left e -> do
          hPutStrLn stderr ("publish-fixture: " <> Text.unpack e)
          exitFailure
        Right () -> putStrLn ("published " <> path <> " to topic " <> Text.unpack topic)
  where
    topic = (.kafkaActivityTopic) config
