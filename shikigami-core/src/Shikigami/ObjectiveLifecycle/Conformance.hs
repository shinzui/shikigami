-- | Pure, public test facade over the private generated behavior contract.
module Shikigami.ObjectiveLifecycle.Conformance (behaviorAssertions, focusedGuardAssertions) where

import Keiki.Core (StepFailure (NoMatchingEdge), reconstituteEither, stepEither)
import Shikigami.Objective.Types (parseObjectiveId)
import Shikigami.ObjectiveLifecycle.BehaviorHoles (behaviorWitnesses)
import Shikigami.ObjectiveLifecycle.Generated.BehaviorContract
import Shikigami.ObjectiveLifecycle.Generated.Domain
import Shikigami.ObjectiveLifecycle.Generated.Transducer (objectiveLifecycleTransducer)

behaviorAssertions :: [(String, Bool)]
behaviorAssertions = [(label, passed)]
  where
    report = behaviorCoverageReport behaviorWitnesses
    passed = behaviorConformancePassed report && all verifiedTotal behaviorRequirements
    verifiedTotal requirement = requirement.guardCoverage /= GuardTotal || requirement.key `elem` report.verified
    label = if passed then "ObjectiveLifecycle behavior" else "ObjectiveLifecycle behavior: " <> show report

-- | Exercise rejected guard inputs against a successfully replayed live state.
-- The accepted control prevents a broken replay seed from proving rejection.
focusedGuardAssertions :: [(String, Bool)]
focusedGuardAssertions =
  [ ("present objective accepts the current identity and advancing revision", accepts (command owner 0 1)),
    ("present objective rejects another identity", rejects (command other 0 1)),
    ("present objective rejects a stale expected revision", rejects (command owner 1 2)),
    ("present objective rejects a non-advancing revision", rejects (command owner 0 0))
  ]
  where
    owner = checked "shikigami_objective_01h455vb4pex5vsknk084sn02q"
    other = checked "shikigami_objective_01h455vb4pex5vsknk084sn02r"
    seed = reconstituteEither objectiveLifecycleTransducer [ObjectiveCreated (ObjectiveCreatedData owner)]
    command identifier expected next = ApplyObjectiveTransition (ApplyObjectiveTransitionData identifier expected next "fixture")
    accepts input = case seed of
      Right state -> case stepEither objectiveLifecycleTransducer state input of Right _ -> True; Left _ -> False
      Left _ -> False
    rejects input = case seed of
      Right state -> case stepEither objectiveLifecycleTransducer state input of Left (NoMatchingEdge _ _) -> True; _ -> False
      Left _ -> False
    checked value = either (error . show) id (parseObjectiveId value)
