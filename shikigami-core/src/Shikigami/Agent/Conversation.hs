module Shikigami.Agent.Conversation
  ( ConversationEnv (..),
    ConversationTurnFailure (..),
    conversationTurnFailureDetail,
    ConversationTurnResult (..),
    conversationIdleTimeoutFireAction,
    conversationIdleTimeoutKind,
    conversationRegistry,
    conversationWorkflowId,
    conversationWorkflowName,
    deliverConversationInput,
    deliverConversationInputFromApp,
    runConversationTurn,
    runConversationTurnWithIdentity,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Command (defaultRunCommandOptions, runCommandWithSqlEvents)
import Keiro.Projection (InlineProjection (InlineProjection, apply))
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerOnceTx)
import Keiro.Workflow
  ( PatchId (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowName (..),
    WorkflowOutcome (..),
    appendJournalEntryReturningId,
    awakeableAllocStepPrefix,
    awakeableStepPrefix,
    continueAsNew,
    currentGeneration,
    currentRunGeneration,
    currentWorkflow,
    loadStepIndex,
    patch,
    restoreSeed,
    runWorkflowWith,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, awakeableIdToUuid, cancelAwakeable, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.App (AppEffects, AppEnv (..), runAppIO)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, genSessionId, idText, parseId)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), SessionCommand (..), StartSessionData (..))
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..), sessionInlineProjection)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Conversation.SessionIndex qualified as SessionIndex
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Principal
  ( AgentIdentity (..),
    ResolvedAgentIdentity,
    compatibilityIdentity,
    resolveAgentIdentity,
    resolvedIdentity,
    resolvedIdentityText,
  )
import Shikigami.Agent.Run (renderLearning)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Input (awaitInput)
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior, runBehaviorAttempt, triggerOnly)
import Shikigami.DanwaConversation.Generated.WorkflowRuntime qualified as ConversationGenerated
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Id.Name (nameBytes)
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig)
import Shikigami.Sink.GrantStore (GrantSource)
import Shikigami.Sink.Types (DanwaTarget (..), SinkOutcome (Delivered, Enqueued), SinkResult (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Text.Read (readMaybe)

data ConversationEnv = ConversationEnv
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    runTimeout :: !NominalDiffTime,
    -- | How long a parked conversation waits for its next human message before
    -- ending its epoch. This is the /between-turns/ window; 'runTimeout' bounds
    -- a turn. There is deliberately no rotation cadence beside it: the journal
    -- is bounded by construction, not by a tuning constant.
    idleTimeout :: !NominalDiffTime,
    danwa :: !DanwaConfig,
    agents :: ![AgentDecl],
    -- | Which grant source the conversation reply's C11 check consults.
    grants :: !GrantSource,
    directory :: !DirectoryHandle
  }

conversationRunTimeout :: ConversationEnv -> NominalDiffTime
conversationRunTimeout ConversationEnv {runTimeout = timeout} = timeout

conversationIdleTimeout :: ConversationEnv -> NominalDiffTime
conversationIdleTimeout ConversationEnv {idleTimeout = timeout} = timeout

declaredPrincipalId :: AgentDecl -> Maybe Text
declaredPrincipalId AgentDecl {identity} = declared <$> identity
  where
    declared IdentityDecl {principal} = principal

data ConversationTurnResult = ConversationTurnResult
  { sessionId :: !SessionId,
    userTurnId :: !Text,
    asstTurnId :: !Text,
    replyMessageId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ConversationTurnFailure
  = ConversationPermanentFailure !Text
  | ConversationTransientFailure !Text
  | ConversationTerminalFailure !Text
  | -- | The conversation is alive and mid-turn, so this message could not be
    -- handed to it yet. Not a failure of anything — it is backpressure, and the
    -- distinction matters because the other three arms are worth an error-level
    -- log and this one is the routine consequence of a human typing while the
    -- agent is still answering.
    ConversationBusy !Text
  deriving stock (Eq, Show)

conversationTurnFailureDetail :: ConversationTurnFailure -> Text
conversationTurnFailureDetail = \case
  ConversationPermanentFailure detail -> detail
  ConversationTransientFailure detail -> detail
  ConversationTerminalFailure detail -> detail
  ConversationBusy detail -> detail

data ConversationStart = ConversationStart
  { agentName :: !Text,
    identity :: !AgentIdentity,
    initialMessage :: !AddressedMessage
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConversationStart where
  toJSON ConversationStart {agentName, identity, initialMessage} =
    Aeson.object
      ( [ "agentName" Aeson..= agentName,
          "initialMessage" Aeson..= initialMessage
        ]
          <> ["identity" Aeson..= identity | identity /= UnresolvedLegacyIdentity]
      )

instance FromJSON ConversationStart where
  parseJSON = Aeson.withObject "ConversationStart" \object ->
    ConversationStart
      <$> object Aeson..: "agentName"
      <*> object Aeson..:? "identity" Aeson..!= UnresolvedLegacyIdentity
      <*> object Aeson..: "initialMessage"

data RecordedTurn = RecordedTurn
  { turnId :: !Text,
    turnIndex :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What the @record-assistant-and-reply@ step journals under the rotating
-- shape.
--
-- The legacy branch journals a bare @(RecordedTurn, SinkResult)@ tuple, which
-- encodes as a two-element JSON array, and it keeps doing so: those bytes are
-- already in journals under @record-assistant-and-reply:\<messageId\>@ and
-- 'docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md'
-- is explicit that a journaled step keeps the bytes it already wrote. The static
-- label is new, so nothing has ever been written under it and it is free to
-- choose a shape the specification can name.
data AssistantTurnAndReply = AssistantTurnAndReply
  { assistantTurn :: !RecordedTurn,
    assistantReply :: !SinkResult
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What woke a parked conversation.
--
-- __One awakeable, two signalers.__ Keiro's @awaitStep@ suspends on one step
-- name and cannot await a sum of two sources, so the race between "the human
-- sent another message" and "this conversation has been idle too long" is
-- resolved by pointing both signalers at the same @next-message@ awakeable and
-- letting the payload say which arrived. Whichever gets there first wins;
-- 'signalAwakeable' returns 'False' on an already-completed awakeable, so the
-- loser is a no-op rather than a conflict. This is the shape
-- "Shikigami.Agent.Approval" already uses for approval deadlines.
data ConversationWake
  = NextMessage !AddressedMessage
  | IdleTimedOut
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What one generation carries to the next.
--
-- __The codec is hand-written and defaults every field on read.__ This value
-- crosses a durable boundary: 'Keiro.Workflow.continueAsNew' snapshots it onto
-- the next generation and 'Keiro.Workflow.restoreSeed' decodes it there, which
-- can happen after a deploy that added a field. A generic 'FromJSON' would
-- require every field it knows about and so would refuse to decode a seed
-- written by the previous binary — the exact replay break
-- 'docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md'
-- describes. Defaulting on read means a new field costs a default, not a
-- stranded conversation.
--
-- @pendingMessage@ is the message this generation is to process. It is
-- 'Nothing' only on generation 0, where the @ConversationStart@ payload supplies
-- it instead. @lastMessageId@ is the message the previous generation finished,
-- which lets a generation recognise a redelivery before doing any work.
data ConversationSeed = ConversationSeed
  { agentName :: !Text,
    identity :: !AgentIdentity,
    turnsSoFar :: !Int,
    pendingMessage :: !(Maybe AddressedMessage),
    lastMessageId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConversationSeed where
  toJSON ConversationSeed {agentName, identity, turnsSoFar, pendingMessage, lastMessageId} =
    Aeson.object
      ( [ "agentName" Aeson..= agentName,
          "turnsSoFar" Aeson..= turnsSoFar,
          "pendingMessage" Aeson..= pendingMessage,
          "lastMessageId" Aeson..= lastMessageId
        ]
          <> ["identity" Aeson..= identity | identity /= UnresolvedLegacyIdentity]
      )

instance FromJSON ConversationSeed where
  parseJSON = Aeson.withObject "ConversationSeed" \o ->
    ConversationSeed
      <$> o Aeson..:? "agentName" Aeson..!= ""
      <*> o Aeson..:? "identity" Aeson..!= UnresolvedLegacyIdentity
      <*> o Aeson..:? "turnsSoFar" Aeson..!= 0
      <*> o Aeson..:? "pendingMessage" Aeson..!= Nothing
      <*> o Aeson..:? "lastMessageId" Aeson..!= Nothing

-- | The seed generation 0 starts from, before any rotation has happened.
emptyConversationSeed :: ConversationSeed
emptyConversationSeed =
  ConversationSeed
    { agentName = "",
      identity = UnresolvedLegacyIdentity,
      turnsSoFar = 0,
      pendingMessage = Nothing,
      lastMessageId = Nothing
    }

-- | The literal lives in @domain\/shikigami-conversation.keiro@ and reaches
-- Haskell through the generated
-- "Shikigami.DanwaConversation.Generated.WorkflowRuntime", so a rename has
-- exactly one place to happen and is gated by @keiro-dsl diff@.
conversationWorkflowName :: WorkflowName
conversationWorkflowName = ConversationGenerated.workflowName

-- | The workflow instance one epoch of a conversation runs as.
--
-- __Epoch 0 keeps the historical id verbatim.__ That is a durable identity, and
-- every instance that existed before epochs did is epoch 0; only epoch 1 and
-- later carry the @:e\<n\>@ suffix, so nothing already journaled moves.
--
-- The epoch has to be here at all because a keiro workflow instance is
-- identified by its workflow id, and a __completed instance cannot be
-- restarted__: running it again replays its recorded completion. A conversation
-- that ended on an idle timeout and then received another message would
-- therefore return the /previous/ epoch's turn result and silently drop the new
-- message. Ending an epoch and opening the next one is only coherent if the next
-- one is a different instance.
conversationWorkflowId :: Int -> AddressedMessage -> WorkflowId
conversationWorkflowId epoch AddressedMessage {conversationId} =
  WorkflowId (conversationWorkflowIdText epoch conversationId)

conversationWorkflowIdText :: Int -> Text -> Text
conversationWorkflowIdText epoch conversationId
  | epoch <= 0 = base
  | otherwise = base <> ":e" <> Text.pack (show epoch)
  where
    base = "danwa-conversation:" <> conversationId

-- | Recover an epoch from a workflow id.
--
-- The id is self-describing, which is what lets the workflow body know its own
-- epoch without a new journaled field: 'completeEpoch' needs it to say which
-- epoch the conversation is moving past, and asking 'currentWorkflow' is exact
-- where a carried counter would be one more thing to keep in step.
conversationEpochOfWorkflowId :: WorkflowId -> Int
conversationEpochOfWorkflowId (WorkflowId wid) =
  case Text.breakOnEnd ":e" wid of
    (prefix, suffix)
      | not (Text.null prefix),
        Just epoch <- readMaybe (Text.unpack suffix) ->
          epoch
    _ -> 0

runConversationTurn :: ConversationEnv -> AgentDecl -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
runConversationTurn env decl msg = do
  admitted <- Directory.identityAdmission (directory env) (declaredPrincipalId decl) (name decl)
  case admitted of
    Left reason -> pure (Left (ConversationPermanentFailure reason))
    Right identity -> runConversationTurnWithIdentity env decl identity msg

runConversationTurnWithIdentity :: ConversationEnv -> AgentDecl -> AgentIdentity -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
runConversationTurnWithIdentity env decl identity msg@AddressedMessage {conversationId = msgConversationId} = do
  -- Which epoch is live is resolved once, before anything addresses the
  -- conversation, because the workflow id depends on it.
  epochE <- runKioku env (SessionIndex.lookupConversationEpoch msgConversationId)
  case epochE of
    Left err -> pure (Left (ConversationTransientFailure (Text.pack (show err))))
    Right epoch -> do
      delivered <- deliverConversationInput env msg
      if delivered
        then driveConversationTurn env epoch msg conversationDriveBudget Nothing
        else do
          -- Nothing accepted the message. Two very different situations look
          -- identical from here, and conflating them is what made the routine
          -- case run down an error path: either this conversation has never run
          -- (so it needs starting), or it is alive and mid-turn between
          -- journaled steps (so it needs a moment, not a restart).
          live <- liveConversationInstance env epoch msg
          if live
            then
              pure
                ( Left
                    ( ConversationBusy
                        ("conversation is mid-turn; redelivering " <> messageId msg)
                    )
                )
            else driveConversationTurn env epoch msg conversationDriveBudget (Just ConversationStart {agentName = name decl, identity, initialMessage = msg})

-- | Is there a workflow instance for this epoch that could still accept work?
--
-- 'Keiro.Workflow.Instance.lookupInstance' is asked directly rather than
-- inferred from the journal, because "has a journal" and "can still accept
-- work" are different questions: a failed or cancelled instance has a journal
-- and would be reported busy forever, which would turn a permanent problem into
-- an unbounded retry.
liveConversationInstance :: ConversationEnv -> Int -> AddressedMessage -> IO Bool
liveConversationInstance env epoch msg = do
  looked <- runKioku env (lookupInstance conversationWorkflowName (conversationWorkflowId epoch msg))
  pure case looked of
    Right (Just WorkflowInstanceRow {status = WfRunning}) -> True
    Right (Just WorkflowInstanceRow {status = WfSuspended}) -> True
    _ -> False

-- | How many times one call will re-enter a rotating workflow before handing the
-- job back to the queue.
--
-- The ordinary case needs two runs: one that accepts the message and rotates,
-- and one in which the new generation actually processes it. The budget is well
-- above that so that concurrent deliveries -- which can rotate a generation out
-- from under this call -- still resolve here rather than bouncing, and small
-- enough that a pathological pattern becomes queue backpressure instead of a
-- spin.
conversationDriveBudget :: Int
conversationDriveBudget = 8

-- | Drive the workflow until this message's turn is journaled.
--
-- __A rotation is progress, not an answer.__ 'continueAsNew' accepts the message
-- and seeds the next generation with it, then unwinds -- so at the moment the
-- run returns 'ContinuedAsNew' the message has been /accepted/ and not yet
-- /processed/; its turn is the work the next generation does. That is why a
-- rotation re-enters rather than returning. It used to map to a terminal
-- failure, which was correct only while nothing rotated: under one turn per
-- generation it would dead-letter every single turn, because
-- 'conversationJobOutcome' maps a terminal failure to a dead-letter.
--
-- The journal is consulted before re-entering, because under concurrent
-- delivery the rotation this call observed may be the one that /followed/ its
-- own turn.
driveConversationTurn ::
  ConversationEnv ->
  Int ->
  AddressedMessage ->
  Int ->
  Maybe ConversationStart ->
  IO (Either ConversationTurnFailure ConversationTurnResult)
driveConversationTurn env epoch msg budget mStart = do
  outcomeE <- runConversationWorkflow env epoch mStart msg
  case outcomeE of
    Left err -> pure (Left (ConversationTransientFailure (Text.pack (show err))))
    Right Failed -> pure (Left (ConversationTerminalFailure "conversation workflow failed"))
    Right Cancelled -> pure (Left (ConversationTerminalFailure "conversation workflow cancelled"))
    Right (Completed result) -> pure (first ConversationPermanentFailure result)
    Right Suspended -> completedTurn env epoch msg
    Right ContinuedAsNew -> do
      loaded <- loadConversationResult env (conversationWorkflowId epoch msg) (messageId msg)
      case loaded of
        Just result -> pure (Right result)
        Nothing
          | budget > 0 -> driveConversationTurn env epoch msg (budget - 1) Nothing
          | otherwise ->
              pure
                ( Left
                    ( ConversationTransientFailure
                        ("conversation workflow kept rotating without recording a turn result for " <> messageId msg)
                    )
                )

-- | Read back the turn this run journaled.
completedTurn :: ConversationEnv -> Int -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
completedTurn env epoch msg = do
  loaded <- loadConversationResult env (conversationWorkflowId epoch msg) (messageId msg)
  pure case loaded of
    Just result -> Right result
    Nothing -> Left (ConversationTransientFailure ("conversation workflow recorded no turn result for " <> messageId msg))

conversationRegistry :: ConversationEnv -> WorkflowRegistry AppEffects
conversationRegistry env =
  Map.singleton conversationWorkflowName (WorkflowDef \_wid -> conversationWorkflow env Nothing)

-- | The conversation workflow, in either of its two shapes.
--
-- The guard is read once per interpreted run and decides everything after it.
-- 'True' is the rotating shape: one generation holds exactly one turn, every
-- label is static, and the generation ends by rotating onto the next. 'False'
-- is the shape this workflow had before rotation existed: one immortal
-- generation holding every turn of the conversation, with a computed
-- @:\<messageId\>@ suffix on every per-turn label so that two turns in one
-- generation do not collide.
--
-- The 'False' branch is not dead code and must not be deleted casually. It is
-- what keeps an instance that was already parked under the old shape coherent —
-- its journal was written with suffixed labels, and replay matches by label. It
-- is also why the guard exists at all:
-- 'docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md' records
-- that @keiro-dsl diff@ refuses any change to a declared body that is not wholly
-- contained in a new patch block, and that a guard the runtime ignores is a
-- declaration nobody honours. Retire both together, per ADR 0004's rule, once no
-- pre-change instance can still resume.
conversationWorkflow ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
conversationWorkflow env mStart = do
  rotating <- patch conversationRotationPatch
  if rotating
    then rotatingConversation env mStart
    else legacyConversation env mStart

-- | One generation, one turn, then rotate.
--
-- The journal is bounded by construction rather than by a tuning constant: a
-- generation's replay cost is a fixed handful of steps no matter how many
-- messages the conversation has carried, because the previous turns are on
-- previous generations and nothing replays them.
rotatingConversation ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
rotatingConversation env mStart = do
  seed <- restoreSeed emptyConversationSeed
  start <- step (StepName "ingest-start") (ingestStart seed mStart)
  decl <- resolveDeclStep env start
  recordedIdentity <- liftIO (requireRight =<< resolveConversationIdentity env decl (start ^. #identity))
  -- __The next turn's promise is armed before this turn's behavior runs.__
  -- Allocating it after the turn would leave the whole turn -- a model call, on
  -- the order of seconds -- as a window in which a message arriving for this
  -- conversation finds nothing to signal and has to be bounced back to the
  -- queue. Allocating it here shrinks that window to the few journaled steps
  -- between a generation starting and this line. The allocation is itself a
  -- journaled step (@awkid:next-message@), so it is replay-stable: a resumed
  -- generation hands out the id it already handed out.
  (aid, awaitWake) <- ConversationGenerated.allocateDeclaredAwait ConversationGenerated.nextMessageAwait
  turn <- processRotatingTurn env recordedIdentity decl (initialMessage start)
  case turn of
    -- The promise was armed before we knew the turn would fail, so it is
    -- withdrawn rather than left pending on a workflow that is about to end.
    Left err -> do
      _ <- cancelAwakeable aid
      pure (Left err)
    Right result -> do
      -- The idle window starts when the conversation goes quiet, so the timer is
      -- armed here rather than beside the allocation -- otherwise the turn's own
      -- duration would count against it. Arming immediately before the await is
      -- also what satisfies keiro's obligation 3 for a custom wake source: the
      -- arm re-runs on every resume until the awaited result is journaled.
      armConversationIdleTimeout (conversationIdleTimeout env) aid
      wake <- awaitWake
      case wake of
        NextMessage next -> continueAsNew (nextConversationSeed seed start next)
        IdleTimedOut -> completeEpoch env recordedIdentity decl (initialMessage start) result

-- | The pre-rotation shape: one immortal generation, suffixed labels.
legacyConversation ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
legacyConversation env mStart = do
  start <- step (StepName "ingest-start") (ingestStart emptyConversationSeed mStart)
  decl <- resolveDeclStep env start
  recordedIdentity <- liftIO (requireRight =<< resolveConversationIdentity env decl (start ^. #identity))
  firstResult <- processTurn env recordedIdentity decl (initialMessage start)
  case firstResult of
    Left err -> pure (Left err)
    Right result -> loop env recordedIdentity decl 1 result

resolveConversationIdentity :: ConversationEnv -> AgentDecl -> AgentIdentity -> IO (Either Text ResolvedAgentIdentity)
resolveConversationIdentity env decl recorded =
  case resolveAgentIdentity recorded of
    Right resolved -> pure (Right resolved)
    Left _ -> do
      admitted <- Directory.identityAdmission (directory env) (declaredPrincipalId decl) (name decl)
      pure (admitted >>= resolveAgentIdentity)

-- | The one place the two entry paths meet.
--
-- Generation 0 of a fresh conversation is driven with an explicit
-- 'ConversationStart' payload. Every later generation is rotated into, so there
-- is no payload — the message to process rides on the seed instead, put there by
-- the rotation that closed the previous generation. Having neither means the
-- workflow was resumed before @ingest-start@ was ever journaled, which is not a
-- state the runtime can invent an answer for.
ingestStart :: (IOE :> es) => ConversationSeed -> Maybe ConversationStart -> Eff es ConversationStart
ingestStart ConversationSeed {agentName = seedAgentName, identity = seedIdentity, pendingMessage} mStart =
  case (pendingMessage, mStart) of
    (Just carried, _) -> pure ConversationStart {agentName = seedAgentName, identity = seedIdentity, initialMessage = carried}
    (Nothing, Just start) -> pure start
    (Nothing, Nothing) ->
      liftIO (ioError (userError "danwa conversation workflow resumed before ingest-start was journaled"))

-- | The seed the next generation starts from.
nextConversationSeed :: ConversationSeed -> ConversationStart -> AddressedMessage -> ConversationSeed
nextConversationSeed ConversationSeed {turnsSoFar} ConversationStart {agentName = startAgentName, identity, initialMessage = finished} next =
  ConversationSeed
    { agentName = startAgentName,
      identity,
      turnsSoFar = turnsSoFar + 1,
      pendingMessage = Just next,
      lastMessageId = Just (messageId finished)
    }

-- | End this epoch: close the kioku session, then let the workflow complete.
--
-- __The session is closed through 'Session.completeWithContext'__, not through
-- the deprecated unsuffixed wrapper, which is confined to kioku's legacy memory
-- space. Shikigami answers the space-and-principal question in exactly one
-- module, "Shikigami.Memory.Access", and this plan does not add a call site that
-- another one has to come back and fix.
--
-- Closing it is the point of the timeout. Nothing ever completed a conversation
-- session before, so @status = "running"@ sessions accumulated forever, and
-- session resolution — which only ever reused a running session — had a growing
-- set to walk. A completed session with a stable @subjectRef@ also gives the
-- next epoch a lineage to continue through kioku's @previousSessionId@.
--
-- The completion is journaled, so a replay of this generation returns the
-- recorded answer rather than re-issuing the command; kioku's own completion is
-- idempotent besides, which is what makes the at-least-once step safe.
completeEpoch ::
  ConversationEnv ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  AddressedMessage ->
  ConversationTurnResult ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
completeEpoch env recordedIdentity decl AddressedMessage {conversationId = msgConversationId} result@ConversationTurnResult {sessionId = sid} = do
  (_, workflowId) <- currentWorkflow
  let thisEpoch = conversationEpochOfWorkflowId workflowId
  _ <- step (StepName "idle-timeout") (liftIO (requireRight =<< endConversationEpoch env recordedIdentity msgConversationId thisEpoch sid))
  pure (Right result)

-- | Close the session and hand the conversation to its next epoch.
--
-- Two writes, in that order and for that reason. Closing the session is the
-- point of the timeout. Advancing the epoch is what makes the /next/ message
-- coherent: this workflow instance is about to complete, and a completed keiro
-- instance cannot be restarted under its id — running it again replays this
-- completion — so the next message must address a different instance or be
-- silently swallowed.
--
-- Both are safe to repeat, which is what a journaled step needs: kioku's
-- completion is idempotent on an already-completed session, and
-- 'SessionIndex.advanceConversationEpoch' sets an absolute value under a
-- @GREATEST@ rather than incrementing.
endConversationEpoch :: ConversationEnv -> ResolvedAgentIdentity -> Text -> Int -> SessionId -> IO (Either Text Text)
endConversationEpoch env recordedIdentity conversationId thisEpoch sid = do
  now <- getCurrentTime
  outcome <-
    runKioku env $
      Session.completeWithContext
        (shikigamiWriteContext recordedIdentity)
        CompleteSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            completedAt = now,
            modelUsed = Nothing,
            summary = Just "conversation idle timeout"
          }
  -- Both layers are bound, per
  -- docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md:
  -- an unreachable store is a different fact from a refused command, and only
  -- the first is worth another attempt.
  case outcome of
    Left storeErr -> pure (Left ("conversation session completion could not reach the store: " <> Text.pack (show storeErr)))
    Right (Left refusal) -> pure (Left ("conversation session completion was refused: " <> Text.pack (show refusal)))
    Right (Right completed) -> do
      advanced <- runKioku env (SessionIndex.advanceConversationEpoch conversationId (thisEpoch + 1) now)
      pure case advanced of
        Left storeErr -> Left ("conversation epoch could not be advanced: " <> Text.pack (show storeErr))
        Right () -> Right (idText completed)

-- | Arm the durable idle timer for this generation's awakeable.
--
-- Modelled on 'Shikigami.Agent.Approval.armApprovalDeadline', including the
-- staleness property that matters most here: the timer id is derived from
-- @(workflowName, workflowId, generation, label)@, and under one turn per
-- generation __the generation is the turn token__. A timer armed for turn /n/
-- belongs to a generation that turn /n+1/ has closed, so it cannot terminate a
-- later turn. There is no second counter to keep in step.
armConversationIdleTimeout ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  NominalDiffTime ->
  AwakeableId ->
  Eff es ()
armConversationIdleTimeout deadline aid = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let request =
        TimerRequest
          { timerId = conversationIdleTimeoutTimerId workflowName workflowId generation,
            processManagerName = unWorkflowName workflowName,
            correlationId = unWorkflowId workflowId,
            fireAt = addUTCTime deadline now,
            payload = Aeson.toJSON (conversationIdleTimeoutPayload aid)
          }
  void (runTransaction (scheduleTimerOnceTx request))

conversationIdleTimeoutTimerId :: WorkflowName -> WorkflowId -> Int -> TimerId
conversationIdleTimeoutTimerId (WorkflowName workflowName) (WorkflowId workflowId) generation =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      nameBytes $
        Text.intercalate ":" ["shikigami", conversationIdleTimeoutKind, workflowName, workflowId, Text.pack (show generation), "next-message"]

data ConversationIdleTimeoutPayload = ConversationIdleTimeoutPayload
  { kind :: !Text,
    awakeableId :: !AwakeableId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

conversationIdleTimeoutPayload :: AwakeableId -> ConversationIdleTimeoutPayload
conversationIdleTimeoutPayload aid =
  ConversationIdleTimeoutPayload
    { kind = conversationIdleTimeoutKind,
      awakeableId = aid
    }

-- | The discriminator that keeps one timer loop able to route three kinds of row.
conversationIdleTimeoutKind :: Text
conversationIdleTimeoutKind = "shikigami.conversation-idle-timeout"

parseConversationIdleTimeoutPayload :: Value -> Maybe AwakeableId
parseConversationIdleTimeoutPayload value = do
  ConversationIdleTimeoutPayload {kind, awakeableId} <- parseMaybe Aeson.parseJSON value
  if kind == conversationIdleTimeoutKind
    then Just awakeableId
    else Nothing

-- | Fire a due conversation idle timer.
--
-- Returns 'Nothing' for a row that is not ours, which is what lets
-- 'Shikigami.Trigger.Scheduler.shikigamiTimerFallback' route three kinds of
-- timer through the one loop the timer table can safely have.
--
-- __A superseded timer settles without effect, and that is by construction
-- rather than by a check alone.__ Its id belongs to a closed generation, and
-- 'signalAwakeable' on an already-resolved or abandoned awakeable returns
-- 'False' without changing the recorded value. The explicit staleness check is
-- the awakeable lookup: an awakeable whose owning workflow has moved on has
-- nothing to append to.
--
-- __A terminal journal refusal is not an error.__ Keiro's obligation 2 for a
-- custom wake source is to expect the append to be declined when the workflow
-- has already gone terminal; the right response is to settle the timer row and
-- deliver nothing, which is what returning 'Nothing' after the signal does.
conversationIdleTimeoutFireAction ::
  (Store :> es, IOE :> es) =>
  TimerRow ->
  Eff es (Maybe EventId)
conversationIdleTimeoutFireAction TimerRow {payload = timerPayload} =
  case parseConversationIdleTimeoutPayload timerPayload of
    Nothing -> pure Nothing
    Just aid -> do
      _ <- signalAwakeable aid IdleTimedOut
      lookupAwakeable (awakeableIdToUuid aid) >>= \case
        Nothing -> pure Nothing
        Just AwakeableRow {ownerWorkflowName, ownerWorkflowId, payload = storedPayload} -> do
          now <- liftIO getCurrentTime
          let eventPayload = fromMaybe (toJSON IdleTimedOut) storedPayload
          Just
            <$> appendJournalEntryReturningId
              (WorkflowName ownerWorkflowName)
              (WorkflowId ownerWorkflowId)
              (StepRecorded (awakeableStepPrefix <> awakeableIdText aid) eventPayload now)

resolveDeclStep :: ConversationEnv -> ConversationStart -> Eff (Workflow : AppEffects) AgentDecl
resolveDeclStep env ConversationStart {agentName} =
  step (StepName "lookup-agent") do
    case find ((== agentName) . name) (agents env) of
      Just decl -> pure decl
      Nothing -> liftIO (ioError (userError ("unknown conversation agent " <> Text.unpack agentName)))

loop ::
  ConversationEnv ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  Int ->
  ConversationTurnResult ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
loop env recordedIdentity decl nextOrdinal _previous = do
  nextMessage <- awaitInput (nextMessageStepName nextOrdinal)
  result <- processTurn env recordedIdentity decl nextMessage
  case result of
    Left err -> pure (Left err)
    Right completed -> loop env recordedIdentity decl (nextOrdinal + 1) completed

processTurn ::
  ConversationEnv ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
processTurn env recordedIdentity decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env recordedIdentity decl msgConversationId))
  userTurn <-
    step (StepName ("record-user:" <> msgMessageId)) $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env recordedIdentity sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
  useRetrySemantics <- patch behaviorRetryPatch
  outputE <-
    if useRetrySemantics
      then step (StepName ("run-behavior-v2:" <> msgMessageId)) do
        prior <- liftIO (loadTurns env sid)
        liftIO
          ( runBehaviorAttempt
              (conversationRunTimeout env)
              (behaviorEnv env)
              decl
              (triggerOnly (behaviorPayload msg prior))
          )
      else do
        legacy <-
          step (StepName ("run-behavior:" <> msgMessageId)) do
            prior <- liftIO (loadTurns env sid)
            -- No recalled memories: a conversation turn's context is the turn
            -- history, and that already travels inside the payload.
            liftIO (first (Text.pack . show) <$> runBehavior (behaviorEnv env) decl (triggerOnly (behaviorPayload msg prior)))
        Right <$> either (liftIO . ioError . userError . Text.unpack) pure legacy
  case outputE of
    Left err -> pure (Left err)
    Right output -> do
      let replyText = renderLearning output
      (asstTurn, sinkResult) <-
        step (assistantReplyStepName msgMessageId) do
          turns <- liftIO (loadTurns env sid)
          let RecordedTurn {turnIndex = userTurnIndex} = userTurn
          assistantAndReplyE <- recordAssistantTurnAndEnqueueReply (directory env) (grants env) recordedIdentity decl sid msg replyText userTurnIndex turns
          either (liftIO . ioError . userError . Text.unpack) pure assistantAndReplyE
      let replyMessageId = sinkResultDetail sinkResult
          RecordedTurn {turnId = recordedUserTurnId} = userTurn
          RecordedTurn {turnId = recordedAsstTurnId} = asstTurn
          result =
            ConversationTurnResult
              { sessionId = sid,
                userTurnId = recordedUserTurnId,
                asstTurnId = recordedAsstTurnId,
                replyMessageId
              }
      Right <$> step (turnResultStepName msgMessageId) (pure result)

-- | One turn, on static labels.
--
-- Every label here is written at most once, because a generation holds exactly
-- one turn. That is the whole reason they can be compile-time wire words with no
-- computed suffix, and therefore the whole reason
-- @domain\/shikigami-conversation.keiro@ can hold them and @just keiro-gate@ can
-- govern them.
--
-- Replay identity for a redelivered message does not come from the label and
-- never did: 'recordTurnOnce' keys on @danwa:user:\<messageId\>@ and
-- 'recordAssistantTurnAndEnqueueReply' keys on @danwa:assistant:\<messageId\>@,
-- and both return the existing turn when it is already recorded. Dropping the
-- suffix costs nothing there.
--
-- Unlike the legacy branch this always takes attempt semantics. An instance can
-- only be on the rotating shape if it started after that shape shipped, and
-- @shikigami-behavior-retry-v1@ has been active far longer, so there is no
-- rotating instance whose journal was written under the pre-retry branch. Not
-- reading the guard here is therefore the honest thing rather than an omission:
-- see docs/adr/0001-declare-only-what-the-runtime-executes.md.
processRotatingTurn ::
  ConversationEnv ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
processRotatingTurn env recordedIdentity decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env recordedIdentity decl msgConversationId))
  userTurn <-
    step (StepName "record-user") $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env recordedIdentity sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
  outputE <-
    step (StepName "run-behavior-v2") do
      prior <- liftIO (loadTurns env sid)
      liftIO
        ( runBehaviorAttempt
            (conversationRunTimeout env)
            (behaviorEnv env)
            decl
            (triggerOnly (behaviorPayload msg prior))
        )
  case outputE of
    Left err -> pure (Left err)
    Right output -> do
      let replyText = renderLearning output
      AssistantTurnAndReply {assistantTurn = asstTurn, assistantReply = sinkResult} <-
        step (StepName "record-assistant-and-reply") do
          turns <- liftIO (loadTurns env sid)
          let RecordedTurn {turnIndex = userTurnIndex} = userTurn
          assistantAndReplyE <- recordAssistantTurnAndEnqueueReply (directory env) (grants env) recordedIdentity decl sid msg replyText userTurnIndex turns
          (recordedTurn, recordedReply) <- either (liftIO . ioError . userError . Text.unpack) pure assistantAndReplyE
          pure AssistantTurnAndReply {assistantTurn = recordedTurn, assistantReply = recordedReply}
      let replyMessageId = sinkResultDetail sinkResult
          RecordedTurn {turnId = recordedUserTurnId} = userTurn
          RecordedTurn {turnId = recordedAsstTurnId} = asstTurn
          result =
            ConversationTurnResult
              { sessionId = sid,
                userTurnId = recordedUserTurnId,
                asstTurnId = recordedAsstTurnId,
                replyMessageId
              }
      Right <$> step (StepName "turn-result") (pure result)

behaviorRetryPatch :: PatchId
behaviorRetryPatch = PatchId "shikigami-behavior-retry-v1"

-- | Which shape an instance runs: rotating with static labels, or the immortal
-- loop with suffixed ones. See 'conversationWorkflow'.
conversationRotationPatch :: PatchId
conversationRotationPatch = PatchId "shikigami-conversation-rotation-v1"

runConversationWorkflow ::
  ConversationEnv ->
  Int ->
  Maybe ConversationStart ->
  AddressedMessage ->
  IO (Either StoreError (WorkflowOutcome (Either Text ConversationTurnResult)))
runConversationWorkflow env epoch mStart msg =
  let AppEnv {connectionSettings, tracer} = appEnv env
   in runEff
        . runTracing tracer
        . runErrorNoCallStack
        . withKirokuStore connectionSettings
        . runStoreResource
        $ runWorkflowWith
          (shikigamiWorkflowRunOptions (appEnv env))
          conversationWorkflowName
          (conversationWorkflowId epoch msg)
          (conversationWorkflow env mStart)

deliverConversationInput :: ConversationEnv -> AddressedMessage -> IO Bool
deliverConversationInput env = deliverConversationInputFromApp (appEnv env)

-- | Signal the live @next-message@ awakeable, if one is armed.
--
-- __The generation is resolved, never assumed.__ This read used to pass a
-- literal @0@, which was correct only because nothing rotated the journal. An
-- awakeable id is allocated fresh in each generation and journaled under
-- @awkid:next-message@ in /that/ generation's step index, so once
-- 'continueAsNew' moves the conversation to generation 1 a generation-0 read
-- finds the previous generation's abandoned id and signals something nobody is
-- awaiting.
deliverConversationInputFromApp :: AppEnv -> AddressedMessage -> IO Bool
deliverConversationInputFromApp appEnv' msg@AddressedMessage {conversationId = msgConversationId} = do
  result <- runAppIO appEnv' do
    -- The epoch decides which instance, the generation decides which journal
    -- inside it. Both are resolved; neither is assumed.
    epoch <- SessionIndex.lookupConversationEpoch msgConversationId
    let wid = conversationWorkflowId epoch msg
    generation <- currentGeneration conversationWorkflowName wid
    stepIndex <- loadStepIndex conversationWorkflowName wid generation
    let aids = pendingInputAids stepIndex
    signalFirst msg aids
  pure case result of
    Right delivered -> delivered
    Left _ -> False

-- | An armed @next-message@ promise, and which shape armed it.
--
-- The shape matters because the two branches await different payloads: the
-- rotating body awaits a 'ConversationWake' so that the idle timer can signal
-- the same promise, while the legacy body awaits a bare 'AddressedMessage'.
-- Signalling the wrong encoding would journal a value the awaiting body cannot
-- decode, and it would do so /successfully/ -- the mistake would surface later
-- as a wedged conversation rather than as a failed delivery.
data PendingInput = PendingInput
  { pendingAid :: !AwakeableId,
    pendingRotating :: !Bool
  }

-- | The armed promises in one generation's step index.
--
-- The label is what says which shape allocated it, so this reads it rather than
-- guessing: the rotating shape allocates the bare @next-message@, the legacy
-- shape allocates @next-message:\<ordinal\>@.
pendingInputAids :: Map.Map Text Value -> [PendingInput]
pendingInputAids stepIndex =
  mapMaybe pending (Map.keys stepIndex)
  where
    rotatingKey = awakeableAllocStepPrefix <> "next-message"
    legacyPrefix = rotatingKey <> ":"

    pending key
      | key == rotatingKey = (\aid -> PendingInput {pendingAid = aid, pendingRotating = True}) <$> parseAid key
      | legacyPrefix `Text.isPrefixOf` key = (\aid -> PendingInput {pendingAid = aid, pendingRotating = False}) <$> parseAid key
      | otherwise = Nothing

    parseAid key =
      Map.lookup key stepIndex >>= parseMaybe Aeson.parseJSON

signalFirst :: (Store :> es, IOE :> es) => AddressedMessage -> [PendingInput] -> Eff es Bool
signalFirst msg = \case
  [] -> pure False
  PendingInput {pendingAid, pendingRotating} : rest -> do
    signalled <-
      if pendingRotating
        then signalAwakeable pendingAid (NextMessage msg)
        else signalAwakeable pendingAid msg
    if signalled then pure True else signalFirst msg rest

-- | Read this message's turn result back out of the journal.
--
-- Two things make this less direct than it looks, and both come from rotation.
--
-- __Which generation.__ The hard-coded @0@ this used to read was right only
-- while nothing rotated. It is now resolved, and /two/ generations are
-- consulted, because how the run ended decides where the answer is: a run that
-- parked left the result on the live generation, and a run that rotated left it
-- on the generation that just closed.
--
-- __Which turn.__ Under the rotating shape the label is the bare @turn-result@,
-- with no message id in it, so "the turn-result step" is not by itself an answer
-- to "the result for /this/ message". The match is made on
-- 'ConversationTurnResult.userTurnId', which is derived from the message id
-- (@danwa:user:\<messageId\>@) and is therefore exact. The legacy shape's
-- suffixed label is tried too, so an instance still on the old branch resolves
-- the same way it always did.
loadConversationResult :: ConversationEnv -> WorkflowId -> Text -> IO (Maybe ConversationTurnResult)
loadConversationResult env workflowId msgMessageId = do
  result <- runAppIO (appEnv env) do
    generation <- currentGeneration conversationWorkflowName workflowId
    traverse (loadStepIndex conversationWorkflowName workflowId) (generationsToSearch generation)
  pure case result of
    Right stepIndexes -> listToMaybe (mapMaybe turnResultIn stepIndexes)
    Left _ -> Nothing
  where
    wantedUserTurnId = "danwa:user:" <> msgMessageId

    -- The live generation first, then the one a rotation just closed. Bounded at
    -- two: a single run advances the conversation by at most one turn, so the
    -- result it journaled cannot be further back than that.
    generationsToSearch generation = [generation, generation - 1]

    turnResultIn stepIndex =
      listToMaybe
        [ result
        | label <- [unStepName (turnResultStepName msgMessageId), "turn-result"],
          Just value <- [Map.lookup label stepIndex],
          Just result <- [parseMaybe Aeson.parseJSON value],
          userTurnId result == wantedUserTurnId
        ]

nextMessageStepName :: Int -> StepName
nextMessageStepName ordinal =
  StepName ("next-message:" <> Text.pack (show ordinal))

turnResultStepName :: Text -> StepName
turnResultStepName msgMessageId =
  StepName ("turn-result:" <> msgMessageId)

assistantReplyStepName :: Text -> StepName
assistantReplyStepName msgMessageId =
  StepName ("record-assistant-and-reply:" <> msgMessageId)

replySinkStepName :: Text -> StepName
replySinkStepName msgMessageId =
  StepName ("danwa-reply:" <> msgMessageId)

behaviorPayload :: AddressedMessage -> [TurnRow] -> Value
behaviorPayload AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, author = msgAuthor, content = msgContent, agentParticipantId = msgAgentParticipantId} priorTurns =
  Aeson.object
    [ "conversationId" Aeson..= msgConversationId,
      "messageId" Aeson..= msgMessageId,
      "author" Aeson..= msgAuthor,
      "content" Aeson..= msgContent,
      "agentParticipantId" Aeson..= msgAgentParticipantId,
      "turns" Aeson..= fmap turnPayload priorTurns
    ]

turnPayload :: TurnRow -> Value
turnPayload TurnRow {turnIndex, role, content} =
  Aeson.object
    [ "turnIndex" Aeson..= turnIndex,
      "role" Aeson..= role,
      "content" Aeson..= content
    ]

-- | Which kioku session this conversation is being recorded into.
--
-- __Keyed, not scanned.__ This used to ask kioku for every session the agent had
-- ever had ('Session.getByScope') and then linearly scan for one whose
-- @subjectRef@ matched — O(sessions per agent) on every turn, over a set that
-- only grows because nothing ever completed a session. It now asks
-- @shikigami.conversation_sessions@ for this one conversation's session id.
--
-- Kioku remains the authority. The index answers with an id and kioku is still
-- asked to produce the row, so a stale or wrong pointer can only cause a miss —
-- it can never invent a session that does not exist.
--
-- Three arms, in cost order:
--
-- 1. The index hits and kioku confirms a running session for this conversation.
--    That is the routine case and the only one a healthy conversation takes.
-- 2. The index misses, or points at something that is no longer this
--    conversation's running session, so the old scan runs and __backfills the
--    index__ if it finds one. This is what repairs a session started before the
--    index existed, and a session whose index write was lost to a crash between
--    the two transactions.
-- 3. Nothing running exists, so a new session is started — __chained to the
--    completed session of the previous epoch, when there is one.__ That is the
--    other half of what the idle timeout buys: an epoch that ends closes its
--    session, and the next message opens a session that names the closed one as
--    its @previousSessionId@, so @Session.getChain@ can walk the whole
--    conversation across every epoch it has had.
resolveSession :: ConversationEnv -> ResolvedAgentIdentity -> AgentDecl -> Text -> IO (Either Text SessionId)
resolveSession env recordedIdentity decl conversationId = do
  indexedE <- runKioku env (SessionIndex.lookupConversationSession conversationId)
  case indexedE of
    Left err -> pure (Left (Text.pack (show err)))
    Right indexed -> do
      confirmed <- maybe (pure Nothing) (confirmIndexedSession env conversationId) indexed
      case confirmed of
        Just sid -> pure (Right sid)
        Nothing -> scanForConversationSession env recordedIdentity decl conversationId indexed

-- | Re-read an indexed pointer through kioku before trusting it.
--
-- Every way this can disagree with kioku — an unparseable id, a session that was
-- deleted, one that belongs to a different conversation, one that is no longer
-- running — resolves to 'Nothing', which sends the caller to the scan. The index
-- is never allowed to be the reason a turn fails.
confirmIndexedSession :: ConversationEnv -> Text -> Text -> IO (Maybe SessionId)
confirmIndexedSession env conversationId sidText =
  case parseId sidText of
    Left _ -> pure Nothing
    Right sid -> do
      rowE <- runKioku env (Session.getById shikigamiMemorySpace sid)
      pure case rowE of
        Right (Right (Just row))
          | isRunningConversationSession conversationId row -> Just sid
        _ -> Nothing

-- | The pre-index resolution path, kept as the repair arm behind an index miss.
--
-- @indexed@ is what the index said, which is 'Nothing' only for a conversation
-- that has never had a session. When it points at a /completed/ session — the
-- shape an idle timeout leaves behind — that id becomes the new session's
-- lineage predecessor.
scanForConversationSession :: ConversationEnv -> ResolvedAgentIdentity -> AgentDecl -> Text -> Maybe Text -> IO (Either Text SessionId)
scanForConversationSession env recordedIdentity decl conversationId indexed = do
  let scope = agentScope recordedIdentity
  rowsE <- runKioku env (Session.getByScope shikigamiMemorySpace scope)
  case rowsE of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    Right (Right rows) ->
      case find (isRunningConversationSession conversationId) rows of
        Just (SessionRow {sessionId = sidText}) ->
          case parseId sidText of
            Left err -> pure (Left ("parse session id: " <> err))
            Right sid -> fmap (const sid) <$> rememberSession env conversationId sid
        Nothing -> do
          previous <- previousEpochSession env conversationId indexed rows
          startSession env recordedIdentity conversationId previous

-- | The completed session the next epoch continues from, if there is one.
--
-- Prefers the index, which points at the most recent session this conversation
-- had, and falls back to the scan's rows for a conversation whose session
-- predates the index. Only a /completed/ session is chained: a failed one is not
-- a predecessor this conversation should claim continuity with, and a running
-- one would have been reused rather than reaching here.
previousEpochSession :: ConversationEnv -> Text -> Maybe Text -> [SessionRow] -> IO (Maybe SessionId)
previousEpochSession env conversationId indexed rows = do
  fromIndex <- maybe (pure Nothing) (completedSessionId env conversationId) indexed
  pure case fromIndex of
    Just sid -> Just sid
    Nothing ->
      listToMaybe
        [ sid
        | SessionRow {sessionId, subjectRef, status} <- rows,
          subjectRef == Just conversationId,
          status == "completed",
          Right sid <- [parseId sessionId]
        ]

completedSessionId :: ConversationEnv -> Text -> Text -> IO (Maybe SessionId)
completedSessionId env conversationId sidText =
  case parseId sidText of
    Left _ -> pure Nothing
    Right sid -> do
      rowE <- runKioku env (Session.getById shikigamiMemorySpace sid)
      pure case rowE of
        Right (Right (Just SessionRow {subjectRef, status}))
          | subjectRef == Just conversationId && status == "completed" -> Just sid
        _ -> Nothing

-- | Point the index at this conversation's session.
--
-- The failure is propagated rather than swallowed. An upsert has no domain
-- refusal layer, so the only way it fails is that the store was unreachable —
-- and 'resolveSession' runs inside the @resolve-session@ journaled step, so
-- surfacing it retries the turn, which re-runs the scan and re-attempts the
-- write. Discarding it would leave the conversation permanently on the scan
-- path with nothing anywhere saying so.
rememberSession :: ConversationEnv -> Text -> SessionId -> IO (Either Text ())
rememberSession env conversationId sid = do
  now <- getCurrentTime
  result <- runKioku env (SessionIndex.rememberConversationSession conversationId (idText sid) now)
  pure (first (\err -> "index conversation session: " <> Text.pack (show err)) result)

isRunningConversationSession :: Text -> SessionRow -> Bool
isRunningConversationSession conversationId (SessionRow {subjectRef = rowSubjectRef, status = rowStatus}) =
  rowSubjectRef == Just conversationId && rowStatus == "running"

-- | Open a session for this conversation, chained to the previous epoch's.
--
-- @previousSessionId@ used to be unconditionally 'Nothing', which was the only
-- honest answer while nothing ever completed a session — there was never a
-- previous epoch to name. Now that an idle timeout closes one, naming it is what
-- makes a conversation's history walkable across epochs.
startSession :: ConversationEnv -> ResolvedAgentIdentity -> Text -> Maybe SessionId -> IO (Either Text SessionId)
startSession env recordedIdentity conversationId previousSession = do
  now <- getCurrentTime
  sid <- genSessionId
  let sessionAgentId = resolvedIdentityText recordedIdentity
  result <-
    runKioku env $
      Session.startWithContext
        (shikigamiWriteContext recordedIdentity)
        StartSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            ownerPrincipal = Nothing,
            agentId = sessionAgentId,
            focus = "conversation",
            scope = agentScope recordedIdentity,
            subjectRef = Just conversationId,
            previousSessionId = previousSession,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  case result of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    -- The index write follows the session it points at, so a crash between the
    -- two leaves a pointer-less session rather than a pointer to nothing. That
    -- is the direction 'scanForConversationSession' can repair.
    Right (Right _) -> fmap (const sid) <$> rememberSession env conversationId sid

loadTurns :: ConversationEnv -> SessionId -> IO [TurnRow]
loadTurns env sid = do
  result <- runKioku env (Session.getTurns shikigamiMemorySpace sid)
  pure case result of
    Right (Right turns) -> turns
    _ -> []

recordTurnOnce :: ConversationEnv -> ResolvedAgentIdentity -> SessionId -> Text -> Maybe Int -> Text -> Text -> [TurnRow] -> IO RecordedTurn
recordTurnOnce env recordedIdentity sid turnId desiredIndex role content turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex} -> pure RecordedTurn {turnId, turnIndex}
    Nothing -> do
      let turnIndex = fromMaybe (length turns) desiredIndex
      requireRight =<< recordTurn env recordedIdentity sid turnId turnIndex role content
      pure RecordedTurn {turnId, turnIndex}

recordAssistantTurnAndEnqueueReply ::
  (IOE :> es, Store :> es, KirokuStoreResource :> es, Error StoreError :> es) =>
  DirectoryHandle ->
  GrantSource ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  Int ->
  [TurnRow] ->
  Eff es (Either Text (RecordedTurn, SinkResult))
recordAssistantTurnAndEnqueueReply directoryHandle grantSource recordedIdentity decl sid msg@AddressedMessage {messageId = msgMessageId} replyText userTurnIndex turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex = existingTurnIndex} -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent directoryHandle grantSource decl sid msg replyText now)
      pure (Right (RecordedTurn {turnId, turnIndex = existingTurnIndex}, AgentWorkflow.preparedSinkResult prepared))
    Nothing -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent directoryHandle grantSource decl sid msg replyText now)
      existing <- Session.getById shikigamiMemorySpace sid
      case existing of
        Left err -> pure (Left (Text.pack (show err)))
        Right Nothing -> pure (Left "SessionNotFound")
        Right (Just SessionRow {status = rowStatus})
          | rowStatus /= "running" -> pure (Left "SessionNotRunning")
          | otherwise -> appendAssistantTurn now prepared
  where
    turnId = "danwa:assistant:" <> msgMessageId
    turnIndex = userTurnIndex + 1

    appendAssistantTurn recordedAt prepared = do
      commandResult <-
        runCommandWithSqlEvents
          defaultRunCommandOptions
          sessionEventStream
          (sessionStream sid)
          ( RecordTurn
              RecordTurnData
                { sessionId = sid,
                  memorySpaceId = shikigamiMemorySpace,
                  actorPrincipal = agentActor recordedIdentity,
                  turnId,
                  turnIndex,
                  role = "assistant",
                  content = replyText,
                  toolSummary = Nothing,
                  promptTokens = Nothing,
                  outputTokens = Nothing,
                  recordedAt
                }
          )
          ( \pairs _appendResult -> do
              applyInlineProjections pairs [sessionInlineProjection, l1TimerScheduleProjection]
              AgentWorkflow.enqueuePreparedSinkIntentTx prepared
          )
      pure case commandResult of
        Left err -> Left (Text.pack (show err))
        Right _ -> Right (RecordedTurn {turnId, turnIndex}, AgentWorkflow.preparedSinkResult prepared)

    applyInlineProjections pairs projections =
      traverse_
        ( \InlineProjection {apply = applyProjection} ->
            traverse_ (uncurry applyProjection) pairs
        )
        projections

prepareConversationReplySinkIntent ::
  DirectoryHandle ->
  GrantSource ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  UTCTime ->
  IO AgentWorkflow.PreparedSinkIntent
prepareConversationReplySinkIntent directoryHandle grantSource decl sid msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId} replyText now =
  AgentWorkflow.prepareSinkIntent
    directoryHandle
    grantSource
    (declaredPrincipalId decl)
    (conversationWorkflowId 0 msg)
    (replySinkStepName msgMessageId)
    (name decl)
    (idText sid)
    0
    Nothing
    ( Just
        DanwaTarget
          { conversationId = msgConversationId,
            parentMessageId = Just msgMessageId
          }
    )
    -- No activity envelope: the turn was triggered by an addressed message.
    -- The shared intent preparation path therefore derives no activity-backed
    -- recipient or channel-egress metadata.
    Nothing
    Agent.DanwaConversation {Agent.topic = "danwa-conversation"}
    (Aeson.object ["reply" Aeson..= replyText])
    now

recordTurn :: ConversationEnv -> ResolvedAgentIdentity -> SessionId -> Text -> Int -> Text -> Text -> IO (Either Text ())
recordTurn env recordedIdentity sid turnId turnIndex role content = do
  now <- getCurrentTime
  result <-
    runKioku env $
      Session.recordTurnWithContext
        (shikigamiWriteContext recordedIdentity)
        RecordTurnData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            turnId,
            turnIndex,
            role,
            content,
            toolSummary = Nothing,
            promptTokens = Nothing,
            outputTokens = Nothing,
            recordedAt = now
          }
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right _) -> Right ()

runKioku :: ConversationEnv -> Eff AppEffects a -> IO (Either StoreError a)
runKioku env action = runAppIO (appEnv env) action

requireRight :: Either Text a -> IO a
requireRight = \case
  Right value -> pure value
  Left err -> ioError (userError (Text.unpack err))

sinkResultDetail :: SinkResult -> Text
sinkResultDetail SinkResult {outcome = Delivered detail} = detail
sinkResultDetail SinkResult {outcome = Enqueued detail} = detail
sinkResultDetail SinkResult {outcome = other} = Text.pack (show other)
