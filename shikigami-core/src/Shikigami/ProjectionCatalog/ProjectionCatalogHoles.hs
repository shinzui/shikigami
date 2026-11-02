-- | Hand-owned bridge to the live evidence boundary. Never reconstruct rich
-- payloads from lifecycle history or accept an unbound application callback.
module Shikigami.ProjectionCatalog.ProjectionCatalogHoles (applyRunEvidenceWriterLive, applyExecutionWriterLive, applyWorkerSessionWriterLive, applyObjectiveWriterLive, applyObjectiveTurnWriterLive, applyObjectiveTrackerWriterLive) where

import Control.Exception (throw)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Execution.Live (MissingLiveExecution (..))
import Shikigami.ExecutionLifecycle.Generated.Domain (ExecutionLifecycleEvent)
import Shikigami.Objective.Live (MissingLiveObjective (..))
import Shikigami.ObjectiveLifecycle.Generated.Domain (ObjectiveLifecycleEvent)
import Shikigami.ObjectiveTurnAdmission.Generated.Domain (ObjectiveTurnAdmissionEvent)
import Shikigami.RunEvidence.Generated.Domain (RunEvidenceEvent)
import Shikigami.RunEvidence.Live (requireLiveEvidence)
import Shikigami.WorkerSession.Live (MissingLiveSession (..))
import Shikigami.WorkerSessionLifecycle.Generated.Domain (WorkerSessionLifecycleEvent)

applyRunEvidenceWriterLive :: RunEvidenceEvent -> RecordedEvent -> Tx.Transaction ()
applyRunEvidenceWriterLive = requireLiveEvidence

applyExecutionWriterLive :: ExecutionLifecycleEvent -> RecordedEvent -> Tx.Transaction ()
applyExecutionWriterLive _ _ = throw MissingLiveExecution

applyWorkerSessionWriterLive :: WorkerSessionLifecycleEvent -> RecordedEvent -> Tx.Transaction ()
applyWorkerSessionWriterLive _ _ = throw MissingLiveSession

applyObjectiveWriterLive :: ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()
applyObjectiveWriterLive _ _ = throw MissingLiveObjective

-- Turn snapshots also require the live admission callback; history contains no
-- protected source-session or objective membership facts.
applyObjectiveTurnWriterLive :: ObjectiveTurnAdmissionEvent -> RecordedEvent -> Tx.Transaction ()
applyObjectiveTurnWriterLive _ _ = throw MissingLiveObjective

applyObjectiveTrackerWriterLive :: ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()
applyObjectiveTrackerWriterLive _ _ = throw MissingLiveObjective
