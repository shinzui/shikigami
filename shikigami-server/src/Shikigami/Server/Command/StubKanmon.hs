module Shikigami.Server.Command.StubKanmon
  ( runStubKanmonCmd,
  )
where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.Sink.Auth (credentialToken)
import Shikigami.Sink.KanmonStub (StubKanmonOptions (..), runStubKanmon)

-- | Run the hermetic Kanmon-compatible proof host. The route destinations are
-- per-invocation arguments; the bearer token comes only from Settei's secret
-- configuration and is never accepted as a command argument.
runStubKanmonCmd :: Int -> [String] -> AppConfig -> IO ()
runStubKanmonCmd listenPort requestedConversations config =
  runStubKanmon
    StubKanmonOptions
      { port = listenPort,
        requireToken = credentialToken <$> (.kanmonToken) config,
        allowedConversations =
          Set.fromList
            (Text.pack <$> if null requestedConversations then ["conv_55012"] else requestedConversations)
      }
