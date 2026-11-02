{-# LANGUAGE DataKinds #-}

-- | A finite first-objective Flow. Static call sites keep operation identities
-- stable when a step commits to the objective owner before its journal append.
module Shikigami.Flow.ObjectiveExample (objectiveExample) where

import Data.Aeson (Value, toJSON)
import Effectful (Eff, (:>))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Flow.Objectives qualified as Objectives
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Operation qualified as Operation
import Shikigami.Objective.Types
import Shikigami.Prelude

objectiveExample :: (Objectives.Objectives :> es) => Value -> Eff es Value
objectiveExample _ = do
  created <- Objectives.create (declarationCoordinate "example-create") request
  case created of
    Right Operation.Reply {result = Operation.ObjectiveCreated receipt} -> do
      actor <- Objectives.identity
      case actor of
        Left err -> pure (toJSON (Left err :: Either ObjectiveError Operation.Reply))
        Right owner -> do
          planned <- Objectives.command (declarationCoordinate "example-plan") receipt.objectiveId receipt.revision (Command.SetAssignments [AssignmentDraft assignment instructions [] owner Pending Nothing Nothing Nothing])
          case planned of
            Right Operation.Reply {result = Operation.ObjectiveUpdated planReceipt} -> do
              progressed <- Objectives.command (declarationCoordinate "example-progress") receipt.objectiveId planReceipt.revision (Command.RecordProgress assignment Working [] [])
              case progressed of
                Left _ -> pure (toJSON progressed)
                Right _ -> toJSON <$> Objectives.inspect (declarationCoordinate "example-inspect") receipt.objectiveId 0 20
            _ -> pure (toJSON planned)
    _ -> pure (toJSON created)
  where
    request = CreateRequest (checked parseTitle "Flow delivery") (checked parseGoal "Reviewed artifact") instructions [Criterion (checked parseCriterionKey "review") (checked parseCriterionDescription "Review combined artifact") HumanVerifiable JourneyOptional] []
    instructions = checked parseInstructions "Continue the finite delivery"
    assignment = checked parseObjectiveAssignmentId "flow-work"
    checked parser = either (error . show) id . parser
