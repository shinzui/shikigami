module Shikigami.Server.Command.StubKawa
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
      { port = port,
        republishTopic = Text.pack <$> mtopic,
        broker = Text.pack <$> mbroker
      }
