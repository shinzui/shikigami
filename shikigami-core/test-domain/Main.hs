module Main (main) where

import Control.Monad (unless)
import Shikigami.ExecutionLifecycle.Conformance qualified as Execution
import Shikigami.Generated.Conformance (runServiceConformanceChecks)
import Shikigami.ObjectiveLifecycle.Conformance qualified as Objective
import Shikigami.RunEvidence.Conformance qualified as RunEvidence
import Shikigami.WorkerSessionLifecycle.Conformance qualified as Session

main :: IO ()
main = do
  generated <- runServiceConformanceChecks
  mapM_ check (generated <> Execution.behaviorAssertions <> Execution.focusedGuardAssertions <> Objective.behaviorAssertions <> Objective.focusedGuardAssertions <> Session.behaviorAssertions <> Session.focusedGuardAssertions <> [("RunEvidence behavior", RunEvidence.runEvidenceBehaviorConformancePassed)] <> RunEvidence.focusedGuardAssertions)
  putStrLn RunEvidence.runEvidenceBehaviorReportJson
  where
    check (label, passed) = do
      unless passed (fail label)
      putStrLn ("PASS " <> label)
