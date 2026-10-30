-- Hand-owned histories exercise all declared lifecycle cells.
module Shikigami.ObjectiveLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.ObjectiveLifecycle.Generated.BehaviorContract
import Shikigami.ObjectiveLifecycle.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    created = ObjectiveCreated (ObjectiveCreatedData "fixture")
    applied = ObjectiveTransitionApplied (ObjectiveTransitionAppliedData "fixture" 0 1 "digest")
    witness requirement =
      LiveWitness
        { key = requirement.key,
          history = case requirement.source of ObjectiveLifecycleMissing -> []; ObjectiveLifecyclePresent -> [created],
          command = if requirement.commandName == "CreateObjective" then CreateObjective (CreateObjectiveData "fixture") else ApplyObjectiveTransition (ApplyObjectiveTransitionData "fixture" 0 1 "digest"),
          expected = case requirement.kind of
            RequiredRejection -> Rejects RejectNoMatchingEdge
            LiveTransition -> Emits ((if requirement.commandName == "CreateObjective" then created else applied) :| [])
            ReplayTransition -> error "no replay-only objective transitions"
        }
