{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | Typed objective work through static journal labels. Flow bodies receive no
-- Store or IO; trusted scope and operation identity stay in this interpreter.
module Shikigami.Flow.Objectives (Objectives, create, inspect, command, commandWithKey, identity, runObjectives) where

import Data.Char (isAlphaNum, isAscii)
import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId, currentRunGeneration, currentWorkflow, step)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Command (Command)
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Origin qualified as Origin
import Shikigami.Objective.Runtime qualified as Runtime
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Types
import Shikigami.Prelude

data Objectives :: Effect where
  ObjectiveCall :: DeclarationCoordinate "objective-label" -> Maybe OperationId -> Operation.Request -> Objectives m (Either ObjectiveError Operation.Reply)
  ObjectiveIdentity :: Objectives m (Either ObjectiveError AgentIdentity)

type instance DispatchOf Objectives = Dynamic

create :: (Objectives :> es) => DeclarationCoordinate "objective-label" -> CreateRequest -> Eff es (Either ObjectiveError Operation.Reply)
create label request = send (ObjectiveCall label Nothing (Operation.CreateObjective request))

inspect :: (Objectives :> es) => DeclarationCoordinate "objective-label" -> ObjectiveId -> Int -> Int -> Eff es (Either ObjectiveError Operation.Reply)
inspect label objective after limit = send (ObjectiveCall label Nothing (Operation.InspectObjective objective after limit))

command :: (Objectives :> es) => DeclarationCoordinate "objective-label" -> ObjectiveId -> StateRevision "objective" -> Command -> Eff es (Either ObjectiveError Operation.Reply)
command label objective expected input = send (ObjectiveCall label Nothing (Operation.ApplyObjectiveCommand objective expected input))

-- A retained domain intent may keep its key across technical generations, but
-- each new generation still needs an admitted scope for the addressed objective.
commandWithKey :: (Objectives :> es) => DeclarationCoordinate "objective-label" -> OperationId -> ObjectiveId -> StateRevision "objective" -> Command -> Eff es (Either ObjectiveError Operation.Reply)
commandWithKey label key objective expected input = send (ObjectiveCall label (Just key) (Operation.ApplyObjectiveCommand objective expected input))

identity :: (Objectives :> es) => Eff es (Either ObjectiveError AgentIdentity)
identity = send ObjectiveIdentity

runObjectives :: (Workflow :> es, IOE :> es) => Maybe Runtime.ObjectiveRuntime -> Either ObjectiveError (Maybe Scope.ObjectiveScope) -> Eff (Objectives : es) a -> Eff es a
runObjectives configured policy = interpret \_ -> \case
  ObjectiveIdentity -> pure ((.identity) . snd <$> enabled)
  ObjectiveCall label retained input -> case enabled of
    Left err -> pure (Left err)
    Right (runtime, scope)
      | not (validLabel (declarationCoordinateText label)) -> pure (Left (ObjectiveInvalid "invalid static objective label"))
      | otherwise -> do
          (name, run) <- currentWorkflow
          generation <- currentRunGeneration
          case scope.source of
            Scope.FlowScope expectedName expectedGeneration
              | name == expectedName && run == scope.runId && toInteger generation == revisionNumber expectedGeneration -> do
                  source <- Origin.flowAuthority scope.identity (originLabel (declarationCoordinateText label))
                  case source of
                    Left err -> pure (Left err)
                    Right authority -> step (StepName ("objectives-" <> declarationCoordinateText label)) $ liftIO do
                      let operation = fromMaybe (Origin.authorityOrigin authority).operationId retained
                      Operation.execute runtime scope authority operation input >>= Operation.requireResolved
            _ -> pure (Left ObjectiveDenied)
  where
    enabled = case (configured, policy) of
      (_, Left err) -> Left err
      (Just runtime, Right (Just scope)) -> Right (runtime, scope)
      _ -> Left ObjectiveDenied
    validLabel raw = not (Text.null raw) && Text.length raw <= 64 && Text.all (\c -> isAscii c && (isAlphaNum c || c `elem` ['-', '_'])) raw && maybe False (isAlphaNum . fst) (Text.uncons raw)
