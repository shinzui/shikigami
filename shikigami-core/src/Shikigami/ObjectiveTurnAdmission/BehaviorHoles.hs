-- | Hand-owned live and duplicate-admission witnesses.
module Shikigami.ObjectiveTurnAdmission.BehaviorHoles (behaviorWitnesses) where

import Shikigami.ObjectiveTurnAdmission.Generated.BehaviorContract
import Shikigami.ObjectiveTurnAdmission.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    admitted = ObjectiveTurnAdmitted (ObjectiveTurnAdmittedData "fixture-coordinate")
    witness requirement =
      LiveWitness
        { key = requirement.key,
          history = case requirement.source of ObjectiveTurnAdmissionMissing -> []; ObjectiveTurnAdmissionPresent -> [admitted],
          command = AdmitObjectiveTurn (AdmitObjectiveTurnData "fixture-coordinate"),
          expected = case requirement.kind of
            RequiredRejection -> Rejects RejectNoMatchingEdge
            LiveTransition -> Emits (admitted :| [])
            ReplayTransition -> error "no replay-only turn transitions"
        }
