{-# LANGUAGE DataKinds #-}

module Shikigami.Server.Command.RenderLifecycle
  ( runRenderLifecycle,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Flow (FlowDef (..), LifecycleDiagram (..))
import Shikigami.Flow.Pack (FlowPack, FlowRegistry, PackFlow (..), RegisteredFlow (..), lookupFlow, registeredFlowNames)
import Shikigami.Server.Command.Flows (composeOrDie)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runRenderLifecycle :: [FlowPack] -> FilePath -> IO ()
runRenderLifecycle packs path = do
  flows <- composeOrDie packs
  result <- loadAgent path
  case result of
    Left (LoadError msg) -> do
      hPutStrLn stderr ("render-lifecycle: load error in " <> path <> ":\n" <> Text.unpack msg)
      exitFailure
    Right decl ->
      case (.behavior) decl of
        Flow {name = flowName} -> renderFlow flows flowName
        other -> do
          hPutStrLn stderr ("render-lifecycle: expected Flow behavior, found " <> show other)
          exitFailure

-- | Print one composed flow's lifecycle diagram. The diagram is declaration
-- data, so asking for it needs none of the machinery for running the flow.
renderFlow :: FlowRegistry -> DeclarationCoordinate "flow" -> IO ()
renderFlow flows flowName =
  case lookupFlow flows flowName of
    Nothing -> do
      hPutStrLn
        stderr
        ( "render-lifecycle: unknown flow "
            <> Text.unpack (declarationCoordinateText flowName)
            <> "; registered flows: "
            <> Text.unpack (Text.intercalate ", " (map declarationCoordinateText (registeredFlowNames flows)))
        )
      exitFailure
    Just entry ->
      TIO.putStrLn entry.flow.definition.lifecycle.mermaid
