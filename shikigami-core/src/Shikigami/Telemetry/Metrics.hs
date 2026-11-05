-- | Provider-free metrics owned by Shikigami.
--
-- The process composition roots decide whether a real or no-op meter provider
-- backs these instruments. Recording code is therefore unconditional and does
-- not need a telemetry-enabled branch. Attribute sets are deliberately bounded:
-- no run ids, message ids, URLs, or error text belong on these instruments.
module Shikigami.Telemetry.Metrics
  ( ShikigamiMetrics (..),
    shikigamiInstrumentationLibrary,
    newShikigamiMetrics,
    recordRunStarted,
    recordRunCompleted,
    recordRunFailed,
    recordRunRetried,
    recordRunDeadLettered,
    recordQueueDepth,
    recordConsumerRecord,
    recordInitiativeCandidate,
    recordInitiativeProposal,
    recordInitiativeAdmission,
    recordInitiativeRefusal,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Int (Int64)
import Data.Text (Text)
import OpenTelemetry.Attributes
  ( Attributes,
    AttrsBuilder,
    addAttributesFromBuilder,
    attr,
    defaultAttributeLimits,
    emptyAttributes,
  )
import OpenTelemetry.Metric.Core
  ( Counter,
    Gauge,
    Meter,
    counterAdd,
    defaultAdvisoryParameters,
    gaugeRecord,
    meterCreateCounterInt64,
    meterCreateGaugeInt64,
  )
import OpenTelemetry.Trace.Core (InstrumentationLibrary (..))

-- | All Shikigami-owned instruments. Field names are direct and strict in
-- accordance with the repository record conventions.
data ShikigamiMetrics = ShikigamiMetrics
  { runsStarted :: !(Counter Int64),
    runsCompleted :: !(Counter Int64),
    runsFailed :: !(Counter Int64),
    runsRetried :: !(Counter Int64),
    runsDeadLettered :: !(Counter Int64),
    queueDepth :: !(Gauge Int64),
    consumerRecords :: !(Counter Int64),
    initiativeCandidates :: !(Counter Int64),
    initiativeProposals :: !(Counter Int64),
    initiativeAdmissions :: !(Counter Int64),
    initiativeRefusals :: !(Counter Int64)
  }

-- | Instrumentation scope shared by every process. Process identity belongs in
-- the OTel resource, while this scope identifies the library that records.
shikigamiInstrumentationLibrary :: InstrumentationLibrary
shikigamiInstrumentationLibrary =
  InstrumentationLibrary
    { libraryName = "shikigami",
      libraryVersion = "0.1.0.0",
      librarySchemaUrl = "",
      libraryAttributes = emptyAttributes
    }

-- | Construct all instruments once from the process meter.
newShikigamiMetrics :: (MonadIO m) => Meter -> m ShikigamiMetrics
newShikigamiMetrics meter = liftIO do
  runsStarted <- counter "shikigami.runs.started" "Run attempts admitted for dispatch."
  runsCompleted <- counter "shikigami.runs.completed" "Run attempts that completed successfully."
  runsFailed <- counter "shikigami.runs.failed" "Run attempts that failed."
  runsRetried <- counter "shikigami.runs.retried" "Failed run attempts scheduled for retry."
  runsDeadLettered <- counter "shikigami.runs.dead_lettered" "Failed run attempts sent to the dead-letter queue."
  queueDepth <- meterCreateGaugeInt64 meter "shikigami.queue.depth" (Just "{job}") (Just "Total run jobs queued or in flight.") defaultAdvisoryParameters
  consumerRecords <- counter "shikigami.consumer.records" "Kafka records delivered to a Shikigami processor."
  initiativeCandidates <- counter "shikigami.initiatives.candidates" "Observed activity recorded for an observer, by verdict."
  initiativeProposals <- counter "shikigami.initiatives.proposals" "Unrequested proposals recorded or resolved, by status."
  initiativeAdmissions <- counter "shikigami.initiatives.admissions" "Admission stages reached under standing policies."
  initiativeRefusals <- counter "shikigami.initiatives.refusals" "Attention, creation and admission refusals, by kind."
  pure ShikigamiMetrics {runsStarted, runsCompleted, runsFailed, runsRetried, runsDeadLettered, queueDepth, consumerRecords, initiativeCandidates, initiativeProposals, initiativeAdmissions, initiativeRefusals}
  where
    counter name description =
      meterCreateCounterInt64 meter name (Just "{run}") (Just description) defaultAdvisoryParameters

recordRunStarted :: (MonadIO m) => ShikigamiMetrics -> Text -> Text -> m ()
recordRunStarted metrics agent trigger =
  recordRun ((.runsStarted) metrics) agent trigger Nothing

recordRunCompleted :: (MonadIO m) => ShikigamiMetrics -> Text -> Text -> m ()
recordRunCompleted metrics agent trigger =
  recordRun ((.runsCompleted) metrics) agent trigger (Just "completed")

recordRunFailed :: (MonadIO m) => ShikigamiMetrics -> Text -> Text -> m ()
recordRunFailed metrics agent trigger =
  recordRun ((.runsFailed) metrics) agent trigger (Just "failed")

recordRunRetried :: (MonadIO m) => ShikigamiMetrics -> Text -> Text -> m ()
recordRunRetried metrics agent trigger =
  recordRun ((.runsRetried) metrics) agent trigger (Just "retried")

recordRunDeadLettered :: (MonadIO m) => ShikigamiMetrics -> Text -> Text -> m ()
recordRunDeadLettered metrics agent trigger =
  recordRun ((.runsDeadLettered) metrics) agent trigger (Just "dead_lettered")

recordQueueDepth :: (MonadIO m) => ShikigamiMetrics -> Int64 -> m ()
recordQueueDepth metrics value = liftIO (gaugeRecord ((.queueDepth) metrics) value emptyAttributes)

recordConsumerRecord :: (MonadIO m) => ShikigamiMetrics -> Text -> m ()
recordConsumerRecord metrics topic =
  liftIO (counterAdd ((.consumerRecords) metrics) 1 (attributes (attr "topic" topic)))

-- | Closed tags only. No proposal, policy or activity identifier, excerpt or error
-- text belongs on these instruments.
recordInitiativeCandidate :: (MonadIO m) => ShikigamiMetrics -> Text -> Maybe Text -> m ()
recordInitiativeCandidate metrics verdict reason =
  liftIO (counterAdd metrics.initiativeCandidates 1 (attributes (attr "verdict" verdict <> maybe mempty (attr "skip.reason") reason)))

recordInitiativeProposal :: (MonadIO m) => ShikigamiMetrics -> Text -> m ()
recordInitiativeProposal metrics status =
  liftIO (counterAdd metrics.initiativeProposals 1 (attributes (attr "status" status)))

recordInitiativeAdmission :: (MonadIO m) => ShikigamiMetrics -> Text -> m ()
recordInitiativeAdmission metrics stage =
  liftIO (counterAdd metrics.initiativeAdmissions 1 (attributes (attr "stage" stage)))

recordInitiativeRefusal :: (MonadIO m) => ShikigamiMetrics -> Text -> m ()
recordInitiativeRefusal metrics kind =
  liftIO (counterAdd metrics.initiativeRefusals 1 (attributes (attr "refusal.kind" kind)))

recordRun :: (MonadIO m) => Counter Int64 -> Text -> Text -> Maybe Text -> m ()
recordRun instrument agent trigger outcome =
  liftIO
    ( counterAdd
        instrument
        1
        ( attributes
            ( attr "agent.name" agent
                <> attr "trigger.kind" trigger
                <> maybe mempty (attr "outcome") outcome
            )
        )
    )

attributes :: AttrsBuilder -> Attributes
attributes = addAttributesFromBuilder defaultAttributeLimits emptyAttributes
