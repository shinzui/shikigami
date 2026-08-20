module Shikigami.Server.Command.RenderLifecycle
  ( runRenderLifecycle,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Flow qualified as Flow
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runRenderLifecycle :: FilePath -> IO ()
runRenderLifecycle path = do
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("render-lifecycle: load error in " <> path <> ":\n" <> Text.unpack msg)
      exitFailure
    Right decl ->
      case behavior decl of
        Flow {name = flowName} -> renderFlow flowName
        other -> do
          hPutStrLn stderr ("render-lifecycle: expected Flow behavior, found " <> show other)
          exitFailure

-- | Print one registered flow's lifecycle diagram.
--
-- This used to mint a session id and a throwaway approval environment purely to
-- satisfy 'Flow.lookupFlow', which took a @FlowRuntime@ because a flow body
-- closed over one. Acknowledgement is a capability now, so asking a flow for its
-- diagram no longer requires the machinery for running it.
renderFlow :: Text -> IO ()
renderFlow flowName =
  case Flow.lookupFlow flowName of
    Nothing -> do
      hPutStrLn stderr ("render-lifecycle: unknown flow " <> Text.unpack flowName)
      exitFailure
    Just flow ->
      TIO.putStrLn (Flow.mermaid (Flow.lifecycle flow))
