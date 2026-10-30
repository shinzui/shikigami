{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- | Cross-run semantic attention reservation for actionable practice reviews.
module Shikigami.PracticeReview.Attention
  ( AttentionKey (..),
    PracticeReviewAttentionEnv (..),
    deriveAttentionKey,
    resolveAttentionRecipient,
    runPracticeReviewAttentionAtomic,
  )
where

import Baikai.Evidence (commitmentDigest)
import Contravariant.Extras (contrazip3)
import Control.Exception qualified as Exception
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowJournalEvent (StepRecorded),
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
    step,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Id.Name (nameBytes)
import Shikigami.PracticeReview
  ( Applicability (..),
    ClaimId (..),
    ContentHash (..),
    ContentReference (..),
    EvidenceId (..),
    EvidenceItem (..),
    OwnerPrincipal (..),
    PracticeKey (..),
    PracticeReviewClaim (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    RecommendedOwner (..),
    ReviewId (..),
    ValidatedPracticeReviewVerdict,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Capability
  ( AttentionRecipientMap,
    AttentionReservationResult (..),
    PracticeReviewAttention (RequestPracticeReviewAttention),
    lookupAttentionRecipient,
  )
import Shikigami.Prelude hiding ((.=))
import Shikigami.Repository (RepoRef (..), RepositoryId (..), relativePathText, revisionText)
import Shikigami.Sink (GrantSource, SinkOutcome (Enqueued), SinkResult (..))
import Shikigami.Sink.Intent
  ( enqueuePreparedSinkIntentTx,
    prepareSinkIntentForRecipientWithMessageId,
    preparedSinkResult,
  )

newtype AttentionKey = AttentionKey {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

data PracticeReviewAttentionEnv = PracticeReviewAttentionEnv
  { agent :: !Text,
    identity :: !AgentIdentity,
    runId :: !Text,
    occurredAt :: !(Maybe UTCTime),
    activity :: !(Maybe ActivityEnvelope),
    grants :: !GrantSource,
    directory :: !DirectoryHandle,
    recipients :: !AttentionRecipientMap
  }

data AttentionProjection = AttentionProjection
  { key :: !AttentionKey,
    schemaVersion :: !Int,
    targetProject :: !Text,
    practiceKey :: !Text,
    classification :: !Text,
    ownerRole :: !Text,
    recipient :: !Text,
    reviewId :: !Text,
    claimEvidenceDigest :: !Text,
    intent :: !Text
  }
  deriving stock (Eq, Show, Generic)

resolveAttentionRecipient :: AttentionRecipientMap -> PracticeReviewVerdict -> Either Text Text
resolveAttentionRecipient recipients PracticeReviewVerdict {recommendedOwner} =
  case recommendedOwner of
    Nothing -> Left "actionable practice review has no recommended owner"
    Just RecommendedOwner {principals} ->
      let owners = [value | OwnerPrincipal value <- principals]
       in maybe
            (Left ("no attention recipient configured for owners: " <> Text.intercalate "+" (sortOn id owners)))
            Right
            (lookupAttentionRecipient recipients owners)

deriveAttentionKey :: AttentionRecipientMap -> ValidatedPracticeReviewVerdict -> Either Text AttentionKey
deriveAttentionKey recipients validated = do
  AttentionProjection {key = key} <- attentionProjection recipients (validatedVerdictValue validated)
  pure key

attentionProjection :: AttentionRecipientMap -> PracticeReviewVerdict -> Either Text AttentionProjection
attentionProjection recipients verdict@PracticeReviewVerdict {reviewId = ReviewId reviewId, practice = PracticeKey practiceKey, classification, recommendedOwner, recommendedAction} = do
  recipient <- resolveAttentionRecipient recipients verdict
  (ownerRole, _) <- case recommendedOwner of
    Nothing -> Left "actionable practice review has no owner role"
    Just RecommendedOwner {role, principals} -> Right (enumText role, principals)
  targetProject <- targetProjectOf verdict
  let semanticProjection =
        Aeson.object
          [ "schemaVersion" .= (1 :: Int),
            "targetProject" .= targetProject,
            "practiceKey" .= Text.toCaseFold (Text.strip practiceKey),
            "classification" .= enumText classification,
            "ownerRole" .= ownerRole,
            "recipient" .= recipient,
            "recommendedAction" .= normalizeWords recommendedAction,
            "materialClaims" .= materialClaimProjection verdict,
            "citedEvidence" .= citedEvidenceProjection verdict
          ]
      claimEvidenceDigest = commitmentDigest semanticProjection
      attentionKey =
        AttentionKey
          ( UUID.toText
              ( UUID.V5.generateNamed
                  attentionNamespace
                  (nameBytes ("practice-review-attention-v1:" <> claimEvidenceDigest))
              )
          )
  pure
    AttentionProjection
      { key = attentionKey,
        schemaVersion = 1,
        targetProject,
        practiceKey = Text.toCaseFold (Text.strip practiceKey),
        classification = enumText classification,
        ownerRole,
        recipient,
        reviewId,
        claimEvidenceDigest,
        intent = Text.take 512 recommendedAction
      }

targetProjectOf :: PracticeReviewVerdict -> Either Text Text
targetProjectOf PracticeReviewVerdict {targetEvidence, applicability} =
  case [repositoryValue | EvidenceItem {content = ContentReference {project = ProjectRef {repository = RepositoryId repositoryValue}}} <- targetEvidence] of
    firstProject : _ -> Right firstProject
    [] -> case applicability of
      Applicability {projects = ProjectRef {repository = RepositoryId repositoryValue} : _} -> Right repositoryValue
      _ -> Left "practice-review attention cannot derive a target project"

materialClaimProjection :: PracticeReviewVerdict -> [Value]
materialClaimProjection PracticeReviewVerdict {claims} =
  [ Aeson.object
      [ "claimId" .= claimId,
        "kind" .= kind,
        "statement" .= normalizeWords statement,
        "evidenceIds" .= sortOn id evidenceIds
      ]
  | PracticeReviewClaim {claimId = ClaimId claimId, kind, statement, material = True, evidenceIds = rawEvidenceIds} <- sortOn claimKey claims,
    let evidenceIds = [value | EvidenceId value <- rawEvidenceIds]
  ]
  where
    claimKey PracticeReviewClaim {claimId = ClaimId claimId} = claimId

citedEvidenceProjection :: PracticeReviewVerdict -> [Value]
citedEvidenceProjection PracticeReviewVerdict {targetEvidence, referenceEvidence, upstreamEvidence, claims} =
  [ Aeson.object
      [ "repository" .= repository,
        "revision" .= revisionText revision,
        "path" .= relativePathText path,
        "contentHash" .= contentHash
      ]
  | EvidenceItem
      { evidenceId,
        content =
          ContentReference
            { project = ProjectRef {repository = RepositoryId repository},
              provenance = RepoRef {revision},
              path,
              contentHash = ContentHash contentHash
            }
      } <-
      sortOn evidenceKey (targetEvidence <> referenceEvidence <> upstreamEvidence),
    Set.member evidenceId citedIds
  ]
  where
    citedIds = Set.fromList [evidenceId | PracticeReviewClaim {material = True, evidenceIds} <- claims, evidenceId <- evidenceIds]
    evidenceKey EvidenceItem {evidenceId = EvidenceId evidenceId} = evidenceId

runPracticeReviewAttentionAtomic ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  PracticeReviewAttentionEnv ->
  Eff (PracticeReviewAttention : es) a ->
  Eff es a
runPracticeReviewAttentionAtomic env =
  interpret \_ -> \case
    RequestPracticeReviewAttention validated -> reserveAttention env validated

reserveAttention ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  PracticeReviewAttentionEnv ->
  ValidatedPracticeReviewVerdict ->
  Eff es AttentionReservationResult
reserveAttention PracticeReviewAttentionEnv {agent, identity, runId, occurredAt, activity, grants, directory, recipients} validated = do
  projection <- either (liftIO . Exception.throwIO . userError . Text.unpack) pure (attentionProjection recipients verdict)
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let stepName = StepName "practice-review-attention"
      AttentionProjection {key = AttentionKey key, reviewId = projectionReviewId} = projection
      messageId = "practice-review-attention:" <> key
      output = attentionOutput projection
      sink = attentionSink projection
  prepared <-
    liftIO
      ( prepareSinkIntentForRecipientWithMessageId
          directory
          grants
          identity
          workflowId
          stepName
          agent
          runId
          0
          occurredAt
          Nothing
          activity
          messageId
          ((.recipient) projection)
          sink
          output
          now
      )
  case preparedSinkResult prepared of
    skipped@SinkResult {outcome = result}
      | not (isEnqueued result) ->
          step stepName (pure (AttentionSkipped (Aeson.toJSON skipped)))
    _ -> do
      let reserved = Reserved {attentionKey = key, outboxMessageId = messageId}
          coalesced = Coalesced {attentionKey = key, outboxMessageId = messageId}
      reservedAppend <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName stepName) (Aeson.toJSON reserved) now)
      coalescedAppend <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName stepName) (Aeson.toJSON coalesced) now)
      transactionResult <- runTransaction do
        inserted <- insertAttentionTx projection messageId now
        winnerOutbox <- lookupAttentionOutboxTx key
        if winnerOutbox /= Just messageId
          then do
            Tx.condemn
            pure (Left "practice-review attention reservation contains an unexpected outbox message id")
          else do
            let result = if inserted then reserved else coalesced
                appendTx = if inserted then reservedAppend else coalescedAppend
            linkAttentionReviewTx key projectionReviewId now
            appendTx >>= \case
              JournalAppended {} -> do
                when inserted (enqueuePreparedSinkIntentTx prepared)
                pure (Right result)
              JournalAlreadyPresent stored ->
                pure (firstText (parseEither Aeson.parseJSON stored))
              JournalRefusedTerminal marker -> do
                Tx.condemn
                pure (Left ("practice-review attention journal refused by terminal marker: " <> marker))
              JournalAppendConflict err -> do
                Tx.condemn
                pure (Left ("practice-review attention journal conflict: " <> Text.pack (show err)))
      either (liftIO . Exception.throwIO . userError . Text.unpack) pure transactionResult
  where
    verdict = validatedVerdictValue validated
    isEnqueued Enqueued {} = True
    isEnqueued _ = False
    firstText = either (Left . Text.pack) Right

attentionOutput :: AttentionProjection -> Value
attentionOutput AttentionProjection {key = AttentionKey attentionKey, reviewId, intent} =
  Aeson.object
    [ "subject_id" .= ("practice-review/" <> reviewId),
      "review_id" .= reviewId,
      "attention_key" .= attentionKey,
      "intent" .= intent,
      "activity_ref" .= ("activity://practice-review/" <> reviewId)
    ]

attentionSink :: AttentionProjection -> Agent.Sink
attentionSink AttentionProjection {intent} =
  Agent.KizashiSignal
    { Agent.source = "shinzui/shikigami",
      Agent.signalType = Agent.TaskCandidate,
      Agent.priority = Agent.High,
      Agent.importance = 8,
      Agent.recipientFrom = Agent.Actor,
      Agent.defaultRecipient = Nothing,
      Agent.intentTemplate = intent,
      Agent.extraContextTags = ["practice-review"]
    }

insertAttentionTx :: AttentionProjection -> Text -> UTCTime -> Tx.Transaction Bool
insertAttentionTx projection outboxMessageId createdAt =
  isJust <$> Tx.statement (projection, outboxMessageId, createdAt) insertAttentionStatement

lookupAttentionOutboxTx :: Text -> Tx.Transaction (Maybe Text)
lookupAttentionOutboxTx key = Tx.statement key lookupAttentionOutboxStatement

linkAttentionReviewTx :: Text -> Text -> UTCTime -> Tx.Transaction ()
linkAttentionReviewTx key reviewId linkedAt = Tx.statement (key, reviewId, linkedAt) linkAttentionReviewStatement

insertAttentionStatement :: Statement (AttentionProjection, Text, UTCTime) (Maybe Text)
insertAttentionStatement =
  preparable
    """
    INSERT INTO shikigami.practice_review_attention
      (attention_key, schema_version, target_project, practice_key,
       classification, owner_role, recipient, originating_review_id,
       claim_evidence_digest, outbox_message_id, created_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    ON CONFLICT DO NOTHING
    RETURNING attention_key
    """
    (contrazip3 attentionProjectionParams textParam timeParam)
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.text)))

attentionProjectionParams :: Encoders.Params AttentionProjection
attentionProjectionParams =
  (view (#key . #value) >$< textParam)
    <> (fromIntegral . view #schemaVersion >$< intParam)
    <> (view #targetProject >$< textParam)
    <> (view #practiceKey >$< textParam)
    <> (view #classification >$< textParam)
    <> (view #ownerRole >$< textParam)
    <> (view #recipient >$< textParam)
    <> (view #reviewId >$< textParam)
    <> (view #claimEvidenceDigest >$< textParam)

lookupAttentionOutboxStatement :: Statement Text (Maybe Text)
lookupAttentionOutboxStatement =
  preparable
    """
    SELECT outbox_message_id
    FROM shikigami.practice_review_attention
    WHERE attention_key = $1
    """
    textParam
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.text)))

linkAttentionReviewStatement :: Statement (Text, Text, UTCTime) ()
linkAttentionReviewStatement =
  preparable
    """
    INSERT INTO shikigami.practice_review_attention_reviews
      (attention_key, review_id, linked_at)
    VALUES ($1, $2, $3)
    ON CONFLICT DO NOTHING
    """
    ( contrazip3
        textParam
        textParam
        timeParam
    )
    Decoders.noResult

textParam :: Encoders.Params Text
textParam = Encoders.param (Encoders.nonNullable Encoders.text)

intParam :: Encoders.Params Int32
intParam = Encoders.param (Encoders.nonNullable Encoders.int4)

timeParam :: Encoders.Params UTCTime
timeParam = Encoders.param (Encoders.nonNullable Encoders.timestamptz)

enumText :: (ToJSON value) => value -> Text
enumText value = case Aeson.toJSON value of
  String rendered -> rendered
  other -> error ("Shikigami.PracticeReview.Attention: expected enum JSON string, got " <> show other)

normalizeWords :: Text -> Text
normalizeWords = Text.unwords . Text.words . Text.strip

attentionNamespace :: UUID.UUID
attentionNamespace =
  UUID.V5.generateNamed
    UUID.V5.namespaceURL
    (ByteString.unpack (TextEncoding.encodeUtf8 "mori://shinzui/shikigami/contracts/practice-review-attention/v1"))
