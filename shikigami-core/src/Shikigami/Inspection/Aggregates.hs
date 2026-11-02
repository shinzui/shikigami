-- | Explicit display authority, independent of protected payload/snapshot JSON.
module Shikigami.Inspection.Aggregates (aggregateCatalog) where

import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Keiki.Core ((!))
import Keiro.Inspection.Aggregate (AggregateInspectors, SomeAggregateInspector (..), aggregateInspector, aggregateInspectors)
import Shikigami.ExecutionLifecycle.Generated.EventStream (executionLifecycleCategory, executionLifecycleEventStream)
import Shikigami.ObjectiveLifecycle.Generated.EventStream (objectiveLifecycleCategory, objectiveLifecycleEventStream)
import Shikigami.ObjectiveTurnAdmission.Generated.EventStream (objectiveTurnAdmissionCategory, objectiveTurnAdmissionEventStream)
import Shikigami.RunEvidence.Generated.EventStream (runEvidenceCategory, runEvidenceEventStream)
import Shikigami.WorkerSessionLifecycle.Generated.EventStream (workerSessionLifecycleCategory, workerSessionLifecycleEventStream)

-- Duplicate descriptors are a startup definition failure. Each display has an
-- explicit allowlist; adding a register never makes it public automatically.
aggregateCatalog :: AggregateInspectors
aggregateCatalog =
  either (error . Text.unpack) id $
    aggregateInspectors
      [ SomeAggregateInspector $
          aggregateInspector "ExecutionLifecycle" executionLifecycleEventStream executionLifecycleCategory \_ registers ->
            object
              [ "executionId" .= (registers ! #executionId),
                "revision" .= (registers ! #revision),
                "pendingReceipts" .= (registers ! #pendingReceipts)
              ],
        SomeAggregateInspector $
          aggregateInspector "WorkerSessionLifecycle" workerSessionLifecycleEventStream workerSessionLifecycleCategory \_ registers ->
            object ["sessionId" .= (registers ! #sessionId), "revision" .= (registers ! #revision)],
        SomeAggregateInspector $
          aggregateInspector "ObjectiveLifecycle" objectiveLifecycleEventStream objectiveLifecycleCategory \_ registers ->
            object ["objectiveId" .= (registers ! #objectiveId), "revision" .= (registers ! #revision)],
        SomeAggregateInspector $
          aggregateInspector "ObjectiveTurnAdmission" objectiveTurnAdmissionEventStream objectiveTurnAdmissionCategory \_ registers ->
            object ["admissionKey" .= (registers ! #source)],
        SomeAggregateInspector $
          aggregateInspector "RunEvidence" runEvidenceEventStream runEvidenceCategory \_ registers ->
            object ["runEvidenceId" .= (registers ! #runEvidenceId), "runId" .= (registers ! #runId)]
      ]
