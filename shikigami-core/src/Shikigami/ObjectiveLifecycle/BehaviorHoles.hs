-- Hand-owned histories exercise all declared lifecycle cells.
module Shikigami.ObjectiveLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.Objective.Types (parseObjectiveId)
import Shikigami.ObjectiveLifecycle.Generated.BehaviorContract
import Shikigami.ObjectiveLifecycle.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    created = ObjectiveCreated (ObjectiveCreatedData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")))
    applied = ObjectiveTransitionApplied (ObjectiveTransitionAppliedData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) 0 1 "digest")
    tracked = TrackerTransitionRecorded (TrackerTransitionRecordedData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) 0 "digest")
    witness requirement =
      LiveWitness
        { key = requirement.key,
          history = case requirement.source of ObjectiveLifecycleMissing -> []; ObjectiveLifecyclePresent -> [created],
          command = if requirement.commandName == "CreateObjective" then CreateObjective (CreateObjectiveData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q"))) else if requirement.commandName == "RecordTrackerTransition" then RecordTrackerTransition (RecordTrackerTransitionData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) 0 "digest") else ApplyObjectiveTransition (ApplyObjectiveTransitionData (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) 0 1 "digest"),
          expected = case requirement.kind of
            RequiredRejection -> Rejects RejectNoMatchingEdge
            LiveTransition -> Emits ((if requirement.commandName == "CreateObjective" then created else if requirement.commandName == "RecordTrackerTransition" then tracked else applied) :| [])
            ReplayTransition -> error "no replay-only objective transitions"
        }
