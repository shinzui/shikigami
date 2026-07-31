module Shikigami.Cli.Commands.RenderLifecycle
  ( runRenderLifecycle,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time (secondsToNominalDiffTime)
import Kioku.Id (genSessionId)
import Shikigami.Agent.Approval qualified as Approval
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

renderFlow :: Text -> IO ()
renderFlow flowName = do
  sid <- genSessionId
  let runtime =
        Flow.FlowRuntime
          { Flow.approval = Approval.defaultApprovalEnv sid,
            Flow.acknowledgementDeadline = secondsToNominalDiffTime 900
          }
  case Flow.lookupFlow runtime flowName of
    Nothing -> do
      hPutStrLn stderr ("render-lifecycle: unknown flow " <> Text.unpack flowName)
      exitFailure
    Just flow ->
      TIO.putStrLn (Flow.mermaid (Flow.lifecycle flow))
