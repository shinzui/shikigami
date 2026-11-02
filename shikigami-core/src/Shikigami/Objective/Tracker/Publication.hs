{-# LANGUAGE DataKinds #-}

-- | The tracker projection runs after the objective projection in the same
-- checked append transaction. Enqueue contains a locator, never the protected
-- summary; only the tracker store can resolve an admitted publication.
module Shikigami.Objective.Tracker.Publication (onObjectiveCommit, trackerDestination) where

import Data.Generics.Labels ()
import Data.UUID.V5 qualified as UUID
import Hasql.Transaction (Transaction)
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), enqueueOutboxTx)
import Shikigami.Objective.Tracker.Mapping (publicationIdentifier, summaryFor)
import Shikigami.Objective.Tracker.Sql qualified as Sql
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude
import Shikigami.StateRevision

trackerDestination :: Text
trackerDestination = "shikigami.objective-tracker.v1"

onObjectiveCommit :: UTCTime -> O.Objective -> Transaction ()
onObjectiveCommit now objective = do
  bindings <- Sql.bindingsFor objective.objectiveId
  forM_ bindings \binding -> when (binding.state == Active && binding.policy.publication == ProgressSummaries) do
    publication <- Sql.latestPublication binding.bindingId
    let summary = summaryFor objective
        previous = case publication of Just (intent, _) -> intent.summary; _ -> binding.exportBase
    when (previous /= summary) do
      identifier <- Sql.require (either (Left . TrackerInvalid) Right (publicationIdentifier binding objective))
      let draft = PublicationIntent TrackerV1 identifier binding.bindingId binding.revision binding.scope binding.connectionDigest binding.policy.revision objective.objectiveId objective.revision now summary (trackerDigest "shikigami.tracker-draft/1" (toJSON summary))
          intent = draft & #digest .~ publicationDigest draft
          receipt = PublicationReceipt TrackerV1 identifier initialRevision Pending Nothing Nothing Nothing Nothing
          event =
            encodeJsonIntegrationEvent
              IntegrationEvent
                { messageId = "objective-tracker:" <> coordinateText identifier,
                  source = "shinzui/shikigami",
                  destination = trackerDestination,
                  key = Just (coordinateText binding.bindingId),
                  eventType = "shikigami.objective-tracker.publication-requested",
                  schemaVersion = 1,
                  contentType = ApplicationJson,
                  schemaReference = Nothing,
                  sourceEventId = Nothing,
                  sourceGlobalPosition = Nothing,
                  payloadBytes = mempty,
                  occurredAt = now,
                  causationId = Nothing,
                  correlationId = Nothing,
                  traceContext = Nothing,
                  attributes = Nothing
                }
              (PublicationDispatch TrackerV1 objective.objectiveId binding.bindingId identifier)
          outboxId = OutboxId (UUID.generateNamed UUID.namespaceURL (nameBytes ("shikigami:objective-tracker:" <> coordinateText identifier)))
      Sql.insertPublication intent receipt
      enqueueOutboxTx (OutboxMessage outboxId event)
