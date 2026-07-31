module Shikigami.Server.Command.PublishFixture
  ( runPublishFixture,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Trigger.Publish (publishEnvelope)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @publish-fixture <file> [--broker B --topic T]@: publish one Activity Envelope
-- from a JSON file onto the activity stream with the keiro-* headers.
runPublishFixture :: Text -> Text -> FilePath -> IO ()
runPublishFixture broker topic path = do
  decoded <- Aeson.eitherDecodeFileStrict' path
  case decoded :: Either String ActivityEnvelope of
    Left e -> do
      hPutStrLn stderr ("publish-fixture: cannot decode " <> path <> ": " <> e)
      exitFailure
    Right env -> do
      r <- publishEnvelope broker topic env
      case r of
        Left e -> do
          hPutStrLn stderr ("publish-fixture: " <> Text.unpack e)
          exitFailure
        Right () -> putStrLn ("published " <> path <> " to topic " <> Text.unpack topic)
