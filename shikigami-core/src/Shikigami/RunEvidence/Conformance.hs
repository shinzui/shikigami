-- | Consumer-owned witnesses for every checked RunEvidence state/command cell.
module Shikigami.RunEvidence.Conformance
  ( runEvidenceBehaviorConformanceReport,
    runEvidenceBehaviorConformancePassed,
    runEvidenceDomainAssertions,
    runEvidenceBehaviorReportJson,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as ByteString
import Shikigami.RunEvidence.BehaviorHoles (behaviorWitnesses)
import Shikigami.RunEvidence.Generated.BehaviorContract
  ( BehaviorConformanceReport (..),
    BehaviorRequirement (..),
    GuardCoverage (..),
    behaviorConformancePassed,
    behaviorCoverageReport,
    behaviorRequirements,
  )
import Shikigami.RunEvidence.Generated.Harness qualified as Harness

runEvidenceBehaviorConformanceReport :: BehaviorConformanceReport
runEvidenceBehaviorConformanceReport = behaviorCoverageReport behaviorWitnesses

runEvidenceBehaviorConformancePassed :: Bool
runEvidenceBehaviorConformancePassed =
  behaviorConformancePassed runEvidenceBehaviorConformanceReport
    && all
      (\requirement -> requirement.key `elem` runEvidenceBehaviorConformanceReport.verified)
      [requirement | requirement <- behaviorRequirements, requirement.guardCoverage == GuardTotal]

-- | A base-only test driver can check the generated contract through this facade.
runEvidenceDomainAssertions :: [(String, Bool)]
runEvidenceDomainAssertions = Harness.harnessAssertions <> [("all behavior obligations have passing witnesses", runEvidenceBehaviorConformancePassed)]

-- | Machine-readable executed evidence, including honest unverified guards.
-- Identity/register equality guards have passing examples but are not proved
-- total by the released DSL; they remain unverified in this report.
runEvidenceBehaviorReportJson :: String
runEvidenceBehaviorReportJson = ByteString.unpack (encode runEvidenceBehaviorConformanceReport)
