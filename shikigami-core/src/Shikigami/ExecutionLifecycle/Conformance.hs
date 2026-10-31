-- | Pure, public test facade over the private generated behavior contract.
module Shikigami.ExecutionLifecycle.Conformance (behaviorAssertions, focusedGuardAssertions) where

import Keiki.Core (StepFailure (NoMatchingEdge), reconstituteEither, stepEither)
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.ExecutionLifecycle.BehaviorHoles (behaviorWitnesses)
import Shikigami.ExecutionLifecycle.Generated.BehaviorContract
import Shikigami.ExecutionLifecycle.Generated.Domain
import Shikigami.ExecutionLifecycle.Generated.Transducer (executionLifecycleTransducer)

behaviorAssertions :: [(String, Bool)]
behaviorAssertions = [(label, passed)]
  where
    report = behaviorCoverageReport behaviorWitnesses
    passed = behaviorConformancePassed report && all verifiedTotal behaviorRequirements
    verifiedTotal requirement = requirement.guardCoverage /= GuardTotal || requirement.key `elem` report.verified
    label = if passed then "ExecutionLifecycle behavior" else "ExecutionLifecycle behavior: " <> show report

-- | Exercise rejected guard inputs against a successfully replayed live state.
-- The accepted control prevents a broken replay seed from proving rejection.
focusedGuardAssertions :: [(String, Bool)]
focusedGuardAssertions =
  [ ("active execution accepts the current identity and advancing revision", accepts (command owner 0 1)),
    ("active execution rejects another identity", rejects (command other 0 1)),
    ("active execution rejects a stale expected revision", rejects (command owner 1 2)),
    ("active execution rejects a non-advancing revision", rejects (command owner 0 0))
  ]
  where
    owner = ExecutionId "fixture"
    other = ExecutionId "other"
    seed = reconstituteEither executionLifecycleTransducer [ExecutionAdmitted (ExecutionAdmittedData owner "fixture")]
    command identifier expected next = AdvanceExecution (AdvanceExecutionData identifier expected next)
    accepts input = case seed of
      Right state -> case stepEither executionLifecycleTransducer state input of Right _ -> True; Left _ -> False
      Left _ -> False
    rejects input = case seed of
      Right state -> case stepEither executionLifecycleTransducer state input of Left (NoMatchingEdge _ _) -> True; _ -> False
      Left _ -> False
