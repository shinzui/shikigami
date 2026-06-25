module Shikigami.Cli.Commands.StubKawa
  ( runStubKawaCmd,
  )
where

import Data.Text qualified as Text
import Shikigami.Sink.KawaStub (StubKawaOptions (..), runStubKawa)

-- | @stub-kawa --port <n> [--republish-topic <t> --broker <host:port>]@: run the kawa
-- ingest doorway stub, optionally republishing accepted envelopes onto a fixture topic.
runStubKawaCmd :: Int -> Maybe String -> Maybe String -> IO ()
runStubKawaCmd port mtopic mbroker =
  runStubKawa
    StubKawaOptions
      { stubPort = port,
        stubRepublishTopic = Text.pack <$> mtopic,
        stubBroker = Text.pack <$> mbroker
      }
