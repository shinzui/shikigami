-- | Pure, public test facade over the private generated behavior contract.
module Shikigami.WorkerSessionLifecycle.Conformance (behaviorAssertions, focusedGuardAssertions) where

import Keiki.Core (StepFailure (NoMatchingEdge), reconstituteEither, stepEither)
import Shikigami.WorkerSession.Types (WorkerSessionId (value), workerSessionId)
import Shikigami.WorkerSessionLifecycle.BehaviorHoles (behaviorWitnesses)
import Shikigami.WorkerSessionLifecycle.Generated.BehaviorContract
import Shikigami.WorkerSessionLifecycle.Generated.Domain
import Shikigami.WorkerSessionLifecycle.Generated.Transducer (workerSessionLifecycleTransducer)

behaviorAssertions :: [(String, Bool)]
behaviorAssertions = [(label, passed)]
  where
    report = behaviorCoverageReport behaviorWitnesses
    passed = behaviorConformancePassed report && all verifiedTotal behaviorRequirements
    verifiedTotal requirement = requirement.guardCoverage /= GuardTotal || requirement.key `elem` report.verified
    label = if passed then "WorkerSessionLifecycle behavior" else "WorkerSessionLifecycle behavior: " <> show report

-- | Exercise rejected guard inputs against a successfully replayed live state.
-- The accepted control prevents a broken replay seed from proving rejection.
focusedGuardAssertions :: [(String, Bool)]
focusedGuardAssertions =
  [ ("idle worker session accepts the current identity and advancing revision", accepts (command owner 0 1)),
    ("idle worker session rejects another identity", rejects (command other 0 1)),
    ("idle worker session rejects a stale expected revision", rejects (command owner 1 2)),
    ("idle worker session rejects a non-advancing revision", rejects (command owner 0 0))
  ]
  where
    owner = workerSessionId "fixture"
    other = workerSessionId "other"
    seed = reconstituteEither workerSessionLifecycleTransducer [WorkerSessionAdmitted (WorkerSessionAdmittedData owner "fixture")]
    command identifier expected next = AcceptSessionMessage (AcceptSessionMessageData identifier expected next)
    accepts input = case seed of
      Right state -> case stepEither workerSessionLifecycleTransducer state input of Right _ -> True; Left _ -> False
      Left _ -> False
    rejects input = case seed of
      Right state -> case stepEither workerSessionLifecycleTransducer state input of Left (NoMatchingEdge _ _) -> True; _ -> False
      Left _ -> False
