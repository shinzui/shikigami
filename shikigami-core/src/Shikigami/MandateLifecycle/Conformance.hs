module Shikigami.MandateLifecycle.Conformance (behaviorAssertions, focusedGuardAssertions) where

import Keiki.Core (reconstituteEither, stepEither)
import Shikigami.MandateLifecycle.BehaviorHoles (behaviorWitnesses)
import Shikigami.MandateLifecycle.Generated.BehaviorContract
import Shikigami.MandateLifecycle.Generated.Domain
import Shikigami.MandateLifecycle.Generated.Transducer (mandateLifecycleTransducer)

behaviorAssertions :: [(String, Bool)]
behaviorAssertions = [("MandateLifecycle behavior: " <> show report, behaviorConformancePassed report)]
  where
    report = behaviorCoverageReport behaviorWitnesses

focusedGuardAssertions :: [(String, Bool)]
focusedGuardAssertions =
  [ ("mandate accepts current advancing revision", accepts (command "mandate" 0 1)),
    ("mandate refuses another identity", not (accepts (command "other" 0 1))),
    ("mandate refuses stale expected revision", not (accepts (command "mandate" 1 2))),
    ("mandate refuses nonadvancing revision", not (accepts (command "mandate" 0 0))),
    ("stopped mandate cannot be readmitted", refusesReadmission)
  ]
  where
    admitted = MandateAdmitted (MandateAdmittedData "mandate")
    seed = reconstituteEither mandateLifecycleTransducer [admitted]
    stopped = reconstituteEither mandateLifecycleTransducer [admitted, MandateStopped (MandateStoppedData "mandate" 0 1)]
    command identifier expected next = AdvanceMandate (AdvanceMandateData identifier expected next)
    refusesReadmission = case stopped of
      Right state -> case stepEither mandateLifecycleTransducer state (AdmitMandate (AdmitMandateData "mandate")) of
        Left _ -> True
        Right _ -> False
      Left _ -> False
    accepts input = case seed of
      Right state -> case stepEither mandateLifecycleTransducer state input of Right _ -> True; Left _ -> False
      Left _ -> False
