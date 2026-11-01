{-# LANGUAGE DataKinds #-}

module Shikigami.Agent.Approval
  ( ApprovalRequest (..),
    ApprovalChannel (..),
    ApprovalDecision (..),
    ApprovalRequirement (..),
    ReviewRequestId,
    parseReviewRequestId,
    reviewRequestIdText,
    ApprovalPolicySnapshot (..),
    reviewRequestIdFor,
    approvalWorkflowId,
    requiresApprovalFor,
    withApprovalChannel,
    approvalPolicyChannel,
    approvalPolicyDeadline,
    autoApprovePolicy,
    parseRequiredSinkKinds,
    renderRequiredSinkKinds,
    parseApprovalChannel,
    renderApprovalChannel,
    ApprovalEnv (..),
    defaultApprovalEnv,
    awaitApproval,
    awaitInput,
    deliverInput,
    resolveApproval,
    approvalTimeoutFireAction,
    approvalTimeoutKind,
    armApprovalDeadline,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bits ((.&.))
import Data.Foldable (traverse_)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import GHC.Records (HasField (..))
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerOnceTx)
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowName (..),
    appendJournalEntryReturningId,
    awakeableStepPrefix,
    currentRunGeneration,
    currentWorkflow,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, awakeableIdToUuid, awakeableNamed, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable)
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shikigami.Agent.Workflow.Input (awaitInput, deliverInput)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.Duration
import Shikigami.Prelude
import Shikigami.Sink.Permission (AgentIdentity, SinkKind (..), sinkKindText)

data ApprovalRequest = ApprovalRequest
  { prompt :: !Text,
    context :: !Value,
    channel :: !ApprovalChannel
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalChannel
  = ViaKizashi
  | ViaDanwa
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalDecision
  = Approved !Value
  | Rejected !Text
  | TimedOut
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalRequirement
  = ApprovalNotRequired
  | ApprovalRequired !ApprovalRequest
  deriving stock (Eq, Show, Generic)

-- | Stable public identity for one human review. This value is safe to retain
-- in logs and attestations; it is deliberately distinct from the random,
-- one-shot 'AwakeableId' that authorizes a decision.
newtype ReviewRequestId = ReviewRequestId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseReviewRequestId :: Text -> Either Text ReviewRequestId
parseReviewRequestId raw = case UUID.fromText (Text.drop 7 raw) of
  Just value
    | let (_, version, variant, _) = UUID.toWords value,
      raw == "review_" <> UUID.toText value,
      version .&. 0xf000 == 0x5000,
      variant .&. 0xc0000000 == 0x80000000 ->
        Right (ReviewRequestId raw)
  _ -> Left "ReviewRequestId requires its canonical UUIDv5 commitment"

instance HasField "value" ReviewRequestId Text where getField = reviewRequestIdText

instance FromJSON ReviewRequestId where
  parseJSON = Aeson.withText "review request identity" (either (fail . Text.unpack) pure . parseReviewRequestId)

-- | The approval policy recorded once in an agent-run journal. Replaying a run
-- consults this value instead of whichever process configuration happens to be
-- active when the run resumes.
data ApprovalPolicySnapshot = ApprovalPolicySnapshot
  { requireFor :: !(Set SinkKind),
    channel :: !ApprovalChannel,
    deadline :: !(Duration "approval")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Derive the stable public review id from durable parent coordinates and a
-- caller-owned request key.
reviewRequestIdFor :: WorkflowName -> WorkflowId -> Int -> Text -> ReviewRequestId
reviewRequestIdFor (WorkflowName workflowName) (WorkflowId workflowId) generation requestKey =
  ReviewRequestId
    ( "review_"
        <> UUID.toText
          ( UUID.V5.generateNamed
              UUID.V5.namespaceURL
              ( nameBytes
                  ( Text.intercalate
                      ":"
                      [ "shikigami",
                        "approval-review",
                        workflowName,
                        workflowId,
                        Text.pack (show generation),
                        requestKey
                      ]
                  )
              )
          )
    )

reviewRequestIdText :: ReviewRequestId -> Text
reviewRequestIdText (ReviewRequestId reviewId) = reviewId

approvalWorkflowId :: ReviewRequestId -> WorkflowId
approvalWorkflowId = WorkflowId . reviewRequestIdText

requiresApprovalFor :: ApprovalPolicySnapshot -> SinkKind -> Bool
requiresApprovalFor ApprovalPolicySnapshot {requireFor} = (`Set.member` requireFor)

withApprovalChannel :: ApprovalChannel -> ApprovalRequest -> ApprovalRequest
withApprovalChannel selected ApprovalRequest {prompt, context} =
  ApprovalRequest {prompt, context, channel = selected}

approvalPolicyChannel :: ApprovalPolicySnapshot -> ApprovalChannel
approvalPolicyChannel ApprovalPolicySnapshot {channel} = channel

approvalPolicyDeadline :: ApprovalPolicySnapshot -> Duration "approval"
approvalPolicyDeadline ApprovalPolicySnapshot {deadline} = deadline

autoApprovePolicy :: Duration "approval" -> ApprovalPolicySnapshot
autoApprovePolicy deadline =
  ApprovalPolicySnapshot
    { requireFor = Set.empty,
      channel = ViaDanwa,
      deadline
    }

parseRequiredSinkKinds :: Text -> Either Text (Set SinkKind)
parseRequiredSinkKinds raw
  | Text.null (Text.strip raw) = Right Set.empty
  | otherwise = do
      parsed <- traverse parseKind pieces
      let selected = Set.fromList parsed
      if Set.size selected == length parsed
        then Right selected
        else Left ("approval.require contains a duplicate; expected unique values from " <> validSinkKinds)
  where
    pieces = fmap Text.strip (Text.splitOn "," raw)
    parseKind name =
      maybe
        (Left ("unknown approval sink kind; expected one of " <> validSinkKinds))
        Right
        (lookup name sinkKindChoices)

renderRequiredSinkKinds :: Set SinkKind -> Text
renderRequiredSinkKinds selected =
  Text.intercalate "," [sinkKindText kind | (_, kind) <- sinkKindChoices, Set.member kind selected]

parseApprovalChannel :: Text -> Either Text ApprovalChannel
parseApprovalChannel = \case
  "danwa" -> Right ViaDanwa
  "kizashi" -> Right ViaKizashi
  _ -> Left "approval.channel must be one of danwa, kizashi"

renderApprovalChannel :: ApprovalChannel -> Text
renderApprovalChannel = \case
  ViaDanwa -> "danwa"
  ViaKizashi -> "kizashi"

sinkKindChoices :: [(Text, SinkKind)]
sinkKindChoices =
  [ (sinkKindText SKawaDigest, SKawaDigest),
    (sinkKindText SKizashiSignal, SKizashiSignal),
    (sinkKindText SReiAction, SReiAction),
    (sinkKindText SDanwaConversation, SDanwaConversation),
    (sinkKindText SChannelEgress, SChannelEgress)
  ]

validSinkKinds :: Text
validSinkKinds = Text.intercalate ", " (fmap fst sinkKindChoices)

data ApprovalTimeoutPayload = ApprovalTimeoutPayload
  { kind :: !Text,
    awakeableId :: !AwakeableId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalEnv = ApprovalEnv
  { currentSession :: !SessionId,
    requiresApproval :: !(AgentIdentity -> SinkKind -> Value -> IO ApprovalRequirement),
    recordPark :: !(SessionId -> AwakeableId -> ApprovalRequest -> IO ()),
    postAsk :: !(ApprovalChannel -> ApprovalRequest -> AwakeableId -> IO ())
  }

defaultApprovalEnv :: SessionId -> ApprovalEnv
defaultApprovalEnv currentSession =
  ApprovalEnv
    { currentSession,
      requiresApproval = \_ _ _ -> pure ApprovalNotRequired,
      recordPark = \_ _ _ -> pure (),
      postAsk = \_ _ _ -> pure ()
    }

awaitApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv ->
  StepName ->
  ApprovalRequest ->
  Maybe (Duration "approval") ->
  Eff es ApprovalDecision
awaitApproval env stepName req deadline = do
  (aid, awaitAnswer) <- awakeableNamed stepName
  _ <-
    step (notifyStepName stepName) $
      liftIO do
        (.recordPark) env ((.currentSession) env) aid req
        (.postAsk) env (requestChannel req) req aid
  traverse_ (armApprovalDeadline stepName aid) deadline
  awaitAnswer

requestChannel :: ApprovalRequest -> ApprovalChannel
requestChannel ApprovalRequest {channel} = channel

resolveApproval :: AppEnv -> AwakeableId -> ApprovalDecision -> IO Bool
resolveApproval appEnv aid decision = do
  result <- runApp appEnv (signalAwakeable aid decision)
  case result of
    Right resolved -> pure resolved
    Left err -> ioError (userError (show err))

approvalTimeoutFireAction ::
  (Store :> es, IOE :> es) =>
  TimerRow ->
  Eff es (Maybe EventId)
approvalTimeoutFireAction TimerRow {payload = timerPayload} =
  case parseApprovalTimeoutPayload timerPayload of
    Nothing -> pure Nothing
    Just aid -> do
      _ <- signalAwakeable aid TimedOut
      lookupAwakeable (awakeableIdToUuid aid) >>= \case
        Nothing -> pure Nothing
        Just AwakeableRow {ownerWorkflowName, ownerWorkflowId, payload = storedPayload} -> do
          now <- liftIO getCurrentTime
          let eventPayload = fromMaybe (toJSON TimedOut) storedPayload
          Just
            <$> appendJournalEntryReturningId
              (WorkflowName ownerWorkflowName)
              (WorkflowId ownerWorkflowId)
              (StepRecorded (awakeableStepPrefix <> awakeableIdText aid) eventPayload now)

-- | Use the shared service interpreter for store ownership and command options.
runApp :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runApp = runAppIO

notifyStepName :: StepName -> StepName
notifyStepName (StepName name) = StepName (name <> ":notify")

armApprovalDeadline ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  AwakeableId ->
  Duration "approval" ->
  Eff es ()
armApprovalDeadline stepName aid deadline = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let request =
        TimerRequest
          { timerId = approvalTimeoutTimerId workflowName workflowId generation stepName,
            processManagerName = unWorkflowName workflowName,
            correlationId = unWorkflowId workflowId,
            fireAt = addUTCTime (durationTime deadline) now,
            payload = Aeson.toJSON (approvalTimeoutPayload aid)
          }
  -- Keiro 0.4 reports whether this arm won the first-arm-wins insert. Arming an
  -- approval deadline is idempotent by construction (the timer id is derived
  -- from the workflow, generation, and step), so either answer is correct here.
  void (runTransaction (scheduleTimerOnceTx request))

approvalTimeoutTimerId :: WorkflowName -> WorkflowId -> Int -> StepName -> TimerId
approvalTimeoutTimerId (WorkflowName workflowName) (WorkflowId workflowId) generation (StepName stepName) =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      nameBytes $
        Text.intercalate ":" ["shikigami", "approval-timeout", workflowName, workflowId, Text.pack (show generation), stepName]

approvalTimeoutPayload :: AwakeableId -> ApprovalTimeoutPayload
approvalTimeoutPayload aid =
  ApprovalTimeoutPayload
    { kind = approvalTimeoutKind,
      awakeableId = aid
    }

parseApprovalTimeoutPayload :: Value -> Maybe AwakeableId
parseApprovalTimeoutPayload value = do
  ApprovalTimeoutPayload {kind, awakeableId} <- parseMaybe Aeson.parseJSON value
  if kind == approvalTimeoutKind
    then Just awakeableId
    else Nothing

approvalTimeoutKind :: Text
approvalTimeoutKind = "shikigami.approval-timeout"
