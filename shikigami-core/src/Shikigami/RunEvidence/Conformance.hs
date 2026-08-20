-- | Consumer-owned witnesses for every checked RunEvidence state/command cell.
module Shikigami.RunEvidence.Conformance
  ( runEvidenceBehaviorConformanceReport,
    runEvidenceBehaviorConformancePassed,
  )
where

import Shikigami.RunEvidence.BehaviorHoles (behaviorWitnesses)
import Shikigami.RunEvidence.Generated.BehaviorContract
  ( BehaviorConformanceReport,
    behaviorConformancePassed,
    behaviorCoverageReport,
  )

runEvidenceBehaviorConformanceReport :: BehaviorConformanceReport
runEvidenceBehaviorConformanceReport = behaviorCoverageReport behaviorWitnesses

runEvidenceBehaviorConformancePassed :: Bool
runEvidenceBehaviorConformancePassed =
  behaviorConformancePassed runEvidenceBehaviorConformanceReport
