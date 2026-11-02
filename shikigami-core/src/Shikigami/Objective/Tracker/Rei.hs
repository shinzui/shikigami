{-# LANGUAGE DataKinds #-}

-- | Rei's typed v2 client. Process composition supplies the manager, endpoint
-- and opaque bearer token. No environment, CLI or database access lives here.
module Shikigami.Objective.Tracker.Rei
  ( reiProviderRevision,
    mkReiProvider,
    publicationDescription,
    candidateReceipts,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.KindID qualified as KindID
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types (statusCode)
import Rei.Api qualified as Api
import Rei.Api.Id qualified as Id
import Rei.Api.Page qualified as Page
import Rei.Api.Problem qualified as Result
import Rei.Client qualified as Client
import Rei.Intention.Api qualified as Intention
import Rei.Intention.Wire qualified as Wire
import Rei.Work.Wire qualified as Work
import Shikigami.Objective.Content (parseInstructions)
import Shikigami.Objective.Tracker.Provider
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types (objectiveIdText)
import Shikigami.Prelude
import Shikigami.StateRevision
import System.Timeout (timeout)

reiProviderRevision :: ProviderRevision
reiProviderRevision = either (error . show) id (parseCoordinate "rei-v2-objectives/1")

mkReiProvider :: Client.ClientEnv -> Client.BearerToken -> ResourceScope -> Either TrackerError Provider
mkReiProvider environment token scope = do
  unless (scope.providerRevision == reiProviderRevision) (Left (TrackerInvalid "unsupported Rei adapter revision"))
  intention <- either (const (Left (TrackerInvalid "invalid Rei intention identifier"))) Right (Id.parseIntentionIdPiece (coordinateText scope.resourceId))
  pure
    Provider
      { capabilities = Capabilities reiProviderRevision OrderedObservations UnconditionalWrites NoIdempotency LookupApplied,
        readResource = \requested -> if requested /= scope then pure ReadDenied else readIntention environment scope intention,
        publish = \intent attempt -> if intent.scope /= scope || intent.digest /= publicationDigest intent || attempt.publicationId /= intent.publicationId then pure PublicationConflict else publishAction environment token intention intent,
        -- A marker and matching payload do not prove that this attempt authored
        -- an action: another authorized Rei writer can copy them. Recovery uses
        -- an exact verified action ID and explicit operator attestation.
        reconcile = \_ _ -> pure StillUnknown,
        verifyReceipt = \intent attempt remote -> if intent.scope /= scope then pure Nothing else verifyRemote environment intention intent attempt remote
      }

readIntention :: Client.ClientEnv -> ResourceScope -> Id.IntentionId -> IO ReadOutcome
readIntention environment scope intention = do
  response <- runBounded environment (Intention.getIntention (Api.intentions Client.reiClient) intention)
  pure case response of
    Right (Result.ReiOk view)
      | view.intentionId == intention -> case snapshotFor view of
          Right snapshot -> case parseRevision (toInteger view.streamPosition) of
            Right position -> Observed (TrackerObservation TrackerV1 scope (Just position) (observationDigest snapshot) snapshot)
            Left _ -> ReadUnavailable
          Left _ -> ReadUnavailable
    Right Result.ReiNotFound {} -> ResourceMissing
    Left (Just (Client.ReiHttpFailure failure)) | statusCode failure.failureStatus `elem` [401, 403] -> ReadDenied
    _ -> ReadUnavailable

snapshotFor :: Wire.IntentionReadModelView -> Either Text RemoteSnapshot
snapshotFor view = RemoteSnapshot <$> parseInstructions view.title <*> parseInstructions (fromMaybe "" view.noteGuidance) <*> pure lifecycle
  where
    lifecycle = case view.status of Wire.Active -> RemoteOpen; Wire.Future -> RemotePlanned; Wire.Completed -> RemoteCompleted; Wire.Abandoned -> RemoteCancelled

publicationDescription :: PublicationIntent -> Text
publicationDescription intent =
  Text.intercalate
    "\n"
    [ "Shikigami objective " <> objectiveIdText intent.objectiveId <> " revision " <> Text.pack (show (revisionNumber intent.objectiveRevision)),
      "publication " <> coordinateText intent.publicationId,
      "payload " <> digestText intent.digest,
      Text.decodeUtf8 (Lazy.toStrict (Aeson.encode intent.summary))
    ]

requestFor :: PublicationIntent -> Wire.RecordActionRequest
requestFor intent = Wire.defaultRecordActionRequest (publicationDescription intent) & #occurredAt .~ Just intent.occurredAt & #timezoneId .~ Just "UTC"

publishAction :: Client.ClientEnv -> Client.BearerToken -> Id.IntentionId -> PublicationIntent -> IO PublishOutcome
publishAction environment token intention intent = do
  response <- runBounded environment (Intention.recordAction (Api.intentionCommands Client.reiClient) (Client.bearerAuth token) intention (requestFor intent))
  pure case response of
    Right (Result.ReiOk view)
      | view.intentionId == intention && view.description == publicationDescription intent && view.occurredAt == intent.occurredAt && view.durationSeconds == Nothing && view.habitId == Nothing && view.polarity == Nothing && view.timezoneId == "UTC" -> either (const OutcomeUnknown) Acknowledged (parseCoordinate (KindID.toText view.actionId))
    Right Result.ReiBadRequest {} -> DefinitivelyRejected
    Right Result.ReiNotFound {} -> DefinitivelyRejected
    Right Result.ReiConflict {} -> PublicationConflict
    Right Result.ReiUnprocessable {} -> DefinitivelyRejected
    Left (Just (Client.ReiHttpFailure failure)) | statusCode failure.failureStatus `elem` [401, 403] -> DefinitivelyRejected
    -- Execution/decode failures and both declared/undeclared 5xx may follow
    -- commit. No HTTP failure is classified as definitely-not-sent here.
    _ -> OutcomeUnknown

verifyRemote :: Client.ClientEnv -> Id.IntentionId -> PublicationIntent -> PublicationAttempt -> RemoteReceiptId -> IO (Maybe VerifiedDelivery)
verifyRemote environment intention intent attempt remote = case KindID.parseText (coordinateText remote) of
  Left _ -> pure Nothing
  Right action -> do
    response <- runBounded environment (Intention.getAction (Api.intentions Client.reiClient) action)
    pure case response of
      Right (Result.ReiOk view) | actionMatches intention intent view && KindID.toText view.actionId == coordinateText remote -> Just (VerifiedDelivery intent.publicationId attempt.attemptId intent.scope remote intent.digest)
      _ -> Nothing

actionMatches :: Id.IntentionId -> PublicationIntent -> Work.ActionView -> Bool
actionMatches intention intent view = view.anchor == Id.IntentionEntity intention && view.description == publicationDescription intent && view.occurredAt == intent.occurredAt && view.durationSeconds == Nothing && view.habitId == Nothing && view.polarity == Nothing && view.timezoneId == Just "UTC"

-- | Bounded discovery for an operator, never proof of authorship or absence.
-- Scoped cursors are preserved and at most four pages of 100 nodes are read.
candidateReceipts :: Client.ClientEnv -> PublicationIntent -> IO (Either TrackerError [RemoteReceiptId])
candidateReceipts environment intent = case Id.parseIntentionIdPiece (coordinateText intent.scope.resourceId) of
  Left _ -> pure (Left (TrackerInvalid "invalid Rei intention identifier"))
  Right intention -> walk intention (4 :: Int) Nothing []
  where
    walk intention remaining cursor found
      | remaining <= 0 = pure (Right found)
      | otherwise = do
          response <- runBounded environment (Intention.listIntentionActions (Api.intentions Client.reiClient) (KindID.toText intention) (Client.forwardPage 100 cursor))
          case response of
            Right (Page.PageOk page) -> do
              let candidates = mapMaybe (either (const Nothing) Just . parseCoordinate . KindID.toText . (.actionId) . (.node)) (filter (actionMatches intention intent . (.node)) page.edges)
                  next = page.pageInfo.endCursor
              if page.pageInfo.hasNextPage && isJust next && next /= cursor then walk intention (remaining - 1) next (found <> candidates) else pure (Right (found <> candidates))
            _ -> pure (Left TrackerUnavailable)

-- An absolute wall duration bounds headers, streamed bodies and decoding as
-- well as the manager's per-read timeout. Timing out a POST remains Unknown.
runBounded :: Client.ClientEnv -> Client.ClientM a -> IO (Either (Maybe Client.ReiClientFailure) a)
runBounded environment action = do
  attempted <- try @SomeException (timeout 20_000_000 (Client.runReiClient environment action))
  case attempted of
    Left exception | Just (_ :: SomeAsyncException) <- fromException exception -> throwIO exception
    Left _ -> pure (Left Nothing)
    Right Nothing -> pure (Left Nothing)
    Right (Just (Left failure)) -> pure (Left (Just failure))
    Right (Just (Right value)) -> pure (Right value)
