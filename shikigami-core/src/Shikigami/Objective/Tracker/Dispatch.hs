{-# LANGUAGE DataKinds #-}

-- | Shared executor, including crash recovery. Transport success may retire an
-- Unknown row into quarantine; only the independent receipt says Delivered.
module Shikigami.Objective.Tracker.Dispatch where

import Data.Generics.Labels ()
import Data.KindID qualified as KindID
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Shikigami.Objective.Authority (Access (..))
import Shikigami.Objective.Store qualified as O
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Provider qualified as P
import Shikigami.Objective.Tracker.Sql qualified as Sql
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude
import Shikigami.StateRevision

data DispatchDisposition = Settled | Deferred | Quarantined
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

transaction :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> Text -> (Access -> OT.Objective -> Transaction ()) -> Eff es (Either TrackerError ())
transaction host objective semantic action = do
  grant <- liftIO (S.admit host (toJSON ("dispatch" :: Text, objective, semantic)))
  either (pure . Left) (\access -> S.mapped (O.trackerTransaction access objective semantic (action access))) grant

lookupPublication :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> PublicationId -> Eff es (Either TrackerError (PublicationIntent, PublicationReceipt))
lookupPublication host objective identifier = S.query host objective \_ _ -> do
  pair@(intent, _) <- Sql.publicationById identifier
  unless (intent.objectiveId == objective) (Sql.abort TrackerDenied)
  pure pair

-- Do not interpret a local expiry or provider lookup absence as non-application.
dispatch :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> PublicationId -> Eff es (Either TrackerError DispatchDisposition)
dispatch host objective identifier = do
  original <- lookupPublication host objective identifier
  case original of
    Left err -> pure (Left err)
    Right (intent, _) | not (matchesConnection host.settings intent.scope intent.connectionDigest) -> pure (Left TrackerConflict)
    Right (intent, _) -> do
      selected <- liftIO (S.provider host intent.scope)
      case selected of
        Left err -> pure (Left err)
        Right provider -> do
          now <- liftIO getCurrentTime
          claimId <- liftIO (freshClaimId)
          claimed <- transaction host objective (coordinateText claimId) \access current -> do
            (retained, receipt) <- Sql.publicationById identifier
            binding <- S.bindingFor objective retained.bindingId
            unless (retained == intent && binding.connectionDigest == retained.connectionDigest && matchesConnection host.settings retained.scope retained.connectionDigest) (Sql.abort TrackerConflict)
            let available = binding.state == Active && binding.revision == retained.bindingRevision && binding.scope == retained.scope && mayExportConnection host.settings access.actor retained.scope && O.mayCoordinate access current && access.settings.enabled == OT.ObjectivesEnabled
                expireUnknown = Sql.savePublicationReceipt (receipt & #revision %~ advanceRevision & #state .~ Unknown & #claim .~ Nothing)
            case receipt.state of
              Pending | not available || isJust receipt.suppression -> Sql.savePublicationReceipt (receipt & #revision %~ advanceRevision & #state .~ Suppressed & #claim .~ Nothing)
              Pending -> do
                earlier <- Sql.hasEarlierUnsettled retained.bindingId retained.objectiveRevision
                unless earlier do
                  attemptId <- Sql.require (either (Left . TrackerInvalid) Right (parseCoordinate (coordinateText claimId)))
                  let attempt = PublicationAttempt attemptId identifier binding.revision provider.capabilities now (addUTCTime 30 now)
                  Sql.insertAttempt attempt
                  Sql.savePublicationReceipt (receipt & #revision %~ advanceRevision & #state .~ Attempting & #attempt .~ Just attempt & #claim .~ Just (AttemptClaim claimId (addUTCTime 30 now)))
              Attempting | maybe True ((<= now) . (.expiresAt)) receipt.claim -> case receipt.attempt of
                Just attempt | available && isNothing receipt.suppression && safeReplay now provider.capabilities attempt.capabilities -> Sql.savePublicationReceipt (receipt & #revision %~ advanceRevision & #claim .~ Just (AttemptClaim claimId (addUTCTime 30 now)))
                _ -> expireUnknown
              Unknown | available && isNothing receipt.suppression -> case receipt.attempt of
                Just attempt | safeReplay now provider.capabilities attempt.capabilities -> Sql.savePublicationReceipt (receipt & #revision %~ advanceRevision & #state .~ Attempting & #claim .~ Just (AttemptClaim claimId (addUTCTime 30 now)))
                _ -> pure ()
              _ -> pure ()
          case claimed of
            Left err -> pure (Left err)
            Right () -> do
              current <- lookupPublication host objective identifier
              case current of
                Right (retained, receipt)
                  | receipt.state == Attempting,
                    Just claim <- receipt.claim,
                    claim.claimId == claimId,
                    Just attempt <- receipt.attempt -> do
                      -- The exact immutable request/attempt is replayed only under
                      -- a retained, still-valid server-key guarantee.
                      beforeSend <- liftIO getCurrentTime
                      if beforeSend >= claim.expiresAt
                        then recordOutcome host objective retained receipt claimId P.OutcomeUnknown
                        else do
                          outcome <- liftIO (S.safeNetwork (provider.publish retained attempt))
                          recordOutcome host objective retained receipt claimId (either (const P.OutcomeUnknown) id outcome)
                Right (_, receipt) -> pure (Right (disposition receipt))
                Left err -> pure (Left err)

freshClaimId :: IO (TrackerCoordinate "attempt-claim")
freshClaimId = do
  value <- KindID.toText <$> KindID.genKindID @"shikigami_tracker_attempt"
  either (ioError . userError . show) pure (parseCoordinate value)

safeReplay :: UTCTime -> Capabilities -> Capabilities -> Bool
safeReplay now current original =
  current.revision == original.revision && case (current.idempotency, original.idempotency) of
    (ServerKeysUntil currentEnd, ServerKeysUntil originalEnd) -> now < originalEnd && originalEnd <= currentEnd
    _ -> False

disposition :: PublicationReceipt -> DispatchDisposition
disposition receipt = case receipt.state of
  Unknown -> Quarantined
  Pending -> Deferred
  Attempting -> Deferred
  _ -> Settled

recordOutcome :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> PublicationIntent -> PublicationReceipt -> TrackerCoordinate "attempt-claim" -> P.PublishOutcome -> Eff es (Either TrackerError DispatchDisposition)
recordOutcome host objective intent original claimId outcome = do
  result <- transaction host objective (coordinateText claimId <> ":outcome") \_ _ -> do
    (retained, receipt) <- Sql.publicationById intent.publicationId
    let ownsClaim = receipt.revision == original.revision && maybe False ((== claimId) . (.claimId)) receipt.claim && receipt.state == Attempting
        exactLateAcknowledgement = case outcome of
          P.Acknowledged _ -> receipt.attempt == original.attempt && receipt.state `elem` [Attempting, Unknown]
          _ -> False
    unless (retained == intent && (ownsClaim || exactLateAcknowledgement)) (Sql.abort TrackerConflict)
    attempt <- maybe (Sql.abort TrackerConflict) pure receipt.attempt
    let state = case outcome of P.Acknowledged _ -> Delivered; P.DefinitelyNotSent -> Pending; P.DefinitivelyRejected -> Rejected; P.PublicationConflict -> Conflict; P.OutcomeUnknown -> Unknown
        verification remote = VerifiedDelivery intent.publicationId attempt.attemptId intent.scope remote intent.digest
        evidence = case outcome of P.Acknowledged remote -> Just (DeliveryEvidence ProviderProved remote (verification remote) Nothing Nothing); _ -> Nothing
        next = receipt & #revision %~ advanceRevision & #state .~ state & #evidence .~ evidence & #claim .~ Nothing
    forM_ evidence (Sql.retainVerification . (.verification))
    Sql.savePublicationReceipt next
  pure (case result of Left err -> Left err; Right () -> Right (case outcome of P.OutcomeUnknown -> Quarantined; P.DefinitelyNotSent -> Deferred; _ -> Settled))

verificationMatches :: PublicationIntent -> PublicationAttempt -> VerifiedDelivery -> Bool
verificationMatches intent attempt evidence = evidence.publicationId == intent.publicationId && evidence.attemptId == attempt.attemptId && evidence.scope == intent.scope && evidence.digest == intent.digest

readProvider :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> ResourceScope -> TrackerDigest "connection-target" -> Bool -> Eff es (Either TrackerError P.Provider)
readProvider host objective scope expected operatorOnly = do
  admitted <- S.query host objective \access current -> do
    if operatorOnly then S.requireReconciliation host access else S.requireManage access current
    connection <- Sql.require (connectionFor host.settings scope)
    unless (connectionDigestFor connection == expected) (Sql.abort TrackerConflict)
    let operator = access.actor `elem` host.settings.reconciliationOperators && case access.actor of OT.LocalOperator _ -> True; _ -> False
    unless (access.actor `elem` connection.useGrants || operator) (Sql.abort TrackerDenied)
    pure ()
  case admitted of Left err -> pure (Left err); Right () -> liftIO (S.provider host scope)

-- Provider proof and operator attestation are distinct facts. A provider that
-- cannot prove absence leaves the barrier intact; suppression cannot remove it.
reconcile :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> PublicationId -> Eff es (Either TrackerError DispatchDisposition)
reconcile host objective identifier = do
  original <- lookupPublication host objective identifier
  case original of
    Left err -> pure (Left err)
    Right (intent, receipt)
      | receipt.state == Unknown,
        Just attempt <- receipt.attempt -> do
          selected <- readProvider host objective intent.scope intent.connectionDigest False
          case selected of
            Left err -> pure (Left err)
            Right provider -> do
              outcome <- liftIO (S.safeNetwork (provider.reconcile intent attempt))
              case outcome of
                Right (P.ProvedApplied verification) | verificationMatches intent attempt verification -> do
                  applied <- transaction host objective (coordinateText identifier <> ":reconcile") \_ _ -> do
                    (_, current) <- Sql.publicationById identifier
                    unless (current.revision == receipt.revision && current.state == Unknown && current.attempt == receipt.attempt) (Sql.abort TrackerConflict)
                    Sql.retainVerification verification
                    Sql.savePublicationReceipt (current & #revision %~ advanceRevision & #state .~ Delivered & #evidence .~ Just (DeliveryEvidence ProviderProved verification.remoteReceiptId verification Nothing Nothing) & #claim .~ Nothing)
                  pure (Settled <$ applied)
                Right P.ProvedNotApplied | provider.capabilities.receiptLookup == LookupAppliedAndSettledAbsence -> do
                  applied <- transaction host objective (coordinateText identifier <> ":absence") \_ _ -> do
                    (_, current) <- Sql.publicationById identifier
                    unless (current.revision == receipt.revision && current.state == Unknown) (Sql.abort TrackerConflict)
                    Sql.savePublicationReceipt (current & #revision %~ advanceRevision & #state .~ (if isJust current.suppression then Suppressed else Pending) & #claim .~ Nothing)
                  pure (Deferred <$ applied)
                _ -> do
                  now <- liftIO getCurrentTime
                  if safeReplay now provider.capabilities attempt.capabilities && isNothing receipt.suppression
                    then dispatch host objective identifier
                    else pure (Right Quarantined)
    Right (_, receipt) -> pure (Right (disposition receipt))

-- An operator may name an exact receipt, but only this provider-read path can
-- retain evidence consumed by the public AttestDelivery command.
verifyDelivery :: (O.ObjectiveEffects es) => S.TrackerHost -> OT.ObjectiveId -> PublicationId -> RemoteReceiptId -> Eff es (Either TrackerError VerifiedDelivery)
verifyDelivery host objective identifier remote = do
  original <- lookupPublication host objective identifier
  case original of
    Left err -> pure (Left err)
    Right (intent, receipt)
      | receipt.state == Unknown,
        Just attempt <- receipt.attempt -> do
          selected <- readProvider host objective intent.scope intent.connectionDigest True
          case selected of
            Left err -> pure (Left err)
            Right provider -> do
              verified <- liftIO (S.safeNetwork (provider.verifyReceipt intent attempt remote))
              case verified of
                Right (Just evidence) | verificationMatches intent attempt evidence && evidence.remoteReceiptId == remote -> do
                  retained <- transaction host objective (coordinateText identifier <> ":verify") \access _ -> do
                    S.requireReconciliation host access
                    (_, current) <- Sql.publicationById identifier
                    unless (current.revision == receipt.revision && current.state == Unknown && current.attempt == receipt.attempt) (Sql.abort TrackerConflict)
                    Sql.retainVerification evidence
                  pure (evidence <$ retained)
                _ -> pure (Left TrackerConflict)
    Right _ -> pure (Left TrackerConflict)
