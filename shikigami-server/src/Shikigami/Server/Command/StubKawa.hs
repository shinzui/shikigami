module Shikigami.Server.Command.StubKawa
  ( runStubKawaCmd,
  )
where

import Data.Text qualified as Text
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.Sink.Auth (credentialToken)
import Shikigami.Sink.KawaStub (StubKawaOptions (..), runStubKawa)

-- | @stub-kawa --port <n> [--republish-topic <t> --broker <host:port>]@: run the kawa
-- ingest doorway stub, optionally republishing accepted envelopes onto a fixture topic.
--
-- The listening port and the republish topic stay command arguments: both are
-- per-invocation choices for a local stub rather than deployment settings. The
-- broker is deployment configuration, so it comes from @kafka.broker@ and
-- @--broker@ is a command-line source for that key. Republishing still happens
-- only when @--republish-topic@ is given; the broker now always has a value
-- because the declaration gives it one.
runStubKawaCmd :: Int -> Maybe String -> AppConfig -> IO ()
runStubKawaCmd listenPort mtopic config =
  runStubKawa
    StubKawaOptions
      { port = listenPort,
        republishTopic = Text.pack <$> mtopic,
        broker = Just (Config.kafkaBroker config),
        requireToken = credentialToken <$> Config.kawaToken config
      }
