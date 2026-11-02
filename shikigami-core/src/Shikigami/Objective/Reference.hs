-- | A selector carried separately from arbitrary trigger input. It grants no authority.
module Shikigami.Objective.Reference (ObjectiveAssociation (..)) where

import Shikigami.Generated.Nominals (ObjectiveId)
import Shikigami.Objective.Keys (ObjectiveAssignmentId)
import Shikigami.Prelude

data ObjectiveAssociation = ObjectiveAssociation
  { objectiveId :: !ObjectiveId,
    assignmentId :: !ObjectiveAssignmentId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
