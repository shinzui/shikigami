-- | Consumer-owned witnesses for every checked RunEvidence state/command cell.
module Shikigami.RunEvidence.Conformance
  ( runEvidenceBehaviorConformanceReport,
    runEvidenceBehaviorConformancePassed,
    runEvidenceDomainAssertions,
  )
where

import Shikigami.RunEvidence.BehaviorHoles (behaviorWitnesses)
import Shikigami.RunEvidence.Generated.BehaviorContract
  ( BehaviorConformanceReport,
    behaviorConformancePassed,
    behaviorCoverageReport,
  )
import Shikigami.RunEvidence.Generated.Harness qualified as Harness

runEvidenceBehaviorConformanceReport :: BehaviorConformanceReport
runEvidenceBehaviorConformanceReport = behaviorCoverageReport behaviorWitnesses

runEvidenceBehaviorConformancePassed :: Bool
runEvidenceBehaviorConformancePassed =
  behaviorConformancePassed runEvidenceBehaviorConformanceReport

-- | A base-only test driver can check the generated contract through this facade.
runEvidenceDomainAssertions :: [(String, Bool)]
runEvidenceDomainAssertions = Harness.harnessAssertions <> [("all behavior obligations have passing witnesses", runEvidenceBehaviorConformancePassed)]
