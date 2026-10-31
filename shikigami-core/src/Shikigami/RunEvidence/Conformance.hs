-- | Consumer-owned witnesses for every checked RunEvidence state/command cell.
module Shikigami.RunEvidence.Conformance
  ( runEvidenceBehaviorConformanceReport,
    runEvidenceBehaviorConformancePassed,
    runEvidenceDomainAssertions,
    runEvidenceBehaviorReportJson,
    focusedGuardAssertions,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as ByteString
import Keiki.Core (StepFailure (NoMatchingEdge), reconstituteEither, stepEither)
import Shikigami.Generated.Nominals (parseRunEvidenceId)
import Shikigami.RunEvidence.BehaviorHoles (behaviorWitnesses)
import Shikigami.RunEvidence.Generated.BehaviorContract
  ( BehaviorConformanceReport (..),
    BehaviorRequirement (..),
    GuardCoverage (..),
    behaviorConformancePassed,
    behaviorCoverageReport,
    behaviorRequirements,
  )
import Shikigami.RunEvidence.Generated.Domain
import Shikigami.RunEvidence.Generated.Harness qualified as Harness
import Shikigami.RunEvidence.Generated.Transducer (runEvidenceTransducer)

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
runEvidenceDomainAssertions = Harness.harnessAssertions <> [("all behavior obligations have passing witnesses", runEvidenceBehaviorConformancePassed)] <> focusedGuardAssertions

-- | Machine-readable executed evidence, including honest unverified guards.
-- Identity/register equality guards have passing examples but are not proved
-- total by the released DSL; they remain unverified in this report.
runEvidenceBehaviorReportJson :: String
runEvidenceBehaviorReportJson = ByteString.unpack (encode runEvidenceBehaviorConformanceReport)

-- | Identity and run correlation are enforced after successful event replay.
focusedGuardAssertions :: [(String, Bool)]
focusedGuardAssertions =
  [ ("profile-bound evidence accepts its current identity and run", accepts (command owner "fixture-run")),
    ("profile-bound evidence rejects another identity", rejects (command other "fixture-run")),
    ("profile-bound evidence rejects another run", rejects (command owner "other-run"))
  ]
  where
    owner = checked "shikigami_run_evidence_01h455vb4pex5vsknk084sn02q"
    other = checked "shikigami_run_evidence_01h455vb4pex5vsknk084sn02r"
    checked value = either (error . show) id (parseRunEvidenceId value)
    seed = reconstituteEither runEvidenceTransducer [ProfileBound (ProfileBoundData owner "fixture-run")]
    command identifier run = StartCollection (StartCollectionData identifier run)
    accepts input = case seed of
      Right state -> case stepEither runEvidenceTransducer state input of Right _ -> True; Left _ -> False
      Left _ -> False
    rejects input = case seed of
      Right state -> case stepEither runEvidenceTransducer state input of Left (NoMatchingEdge _ _) -> True; _ -> False
      Left _ -> False
