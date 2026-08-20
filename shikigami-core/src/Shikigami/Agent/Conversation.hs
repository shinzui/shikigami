module Shikigami.Agent.Conversation
  ( ConversationEnv (..),
    ConversationTurnFailure (..),
    conversationTurnFailureDetail,
    ConversationTurnResult (..),
    conversationRegistry,
    conversationWorkflowId,
    conversationWorkflowName,
    deliverConversationInput,
    deliverConversationInputFromApp,
    runConversationTurn,
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
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Command (defaultRunCommandOptions, runCommandWithSqlEvents)
import Keiro.Projection (InlineProjection (InlineProjection, apply))
import Keiro.Workflow
  ( PatchId (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    awakeableAllocStepPrefix,
    continueAsNew,
    currentGeneration,
    loadStepIndex,
    patch,
    restoreSeed,
    runWorkflowWith,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.App (AppEffects, AppEnv (..), runAppIO)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, genSessionId, idText, parseId)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (RecordTurnData (..), SessionCommand (..), StartSessionData (..))
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..), sessionInlineProjection)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Conversation.SessionIndex qualified as SessionIndex
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Run (renderLearning)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Input (awaitInput)
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior, runBehaviorAttempt, triggerOnly)
import Shikigami.DanwaConversation.Generated.WorkflowRuntime qualified as ConversationGenerated
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig)
import Shikigami.Sink.GrantStore (GrantSource)
import Shikigami.Sink.Types (DanwaTarget (..), SinkOutcome (Delivered), SinkResult (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)

data ConversationEnv = ConversationEnv
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    runTimeout :: !NominalDiffTime,
    danwa :: !DanwaConfig,
    agents :: ![AgentDecl],
    -- | Which grant source the conversation reply's C11 check consults.
    grants :: !GrantSource
  }

conversationRunTimeout :: ConversationEnv -> NominalDiffTime
conversationRunTimeout ConversationEnv {runTimeout = timeout} = timeout

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
  deriving stock (Eq, Show)

conversationTurnFailureDetail :: ConversationTurnFailure -> Text
conversationTurnFailureDetail = \case
  ConversationPermanentFailure detail -> detail
  ConversationTransientFailure detail -> detail
  ConversationTerminalFailure detail -> detail

data ConversationStart = ConversationStart
  { agentName :: !Text,
    initialMessage :: !AddressedMessage
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

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
    turnsSoFar :: !Int,
    pendingMessage :: !(Maybe AddressedMessage),
    lastMessageId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConversationSeed where
  toJSON ConversationSeed {agentName, turnsSoFar, pendingMessage, lastMessageId} =
    Aeson.object
      [ "agentName" Aeson..= agentName,
        "turnsSoFar" Aeson..= turnsSoFar,
        "pendingMessage" Aeson..= pendingMessage,
        "lastMessageId" Aeson..= lastMessageId
      ]

instance FromJSON ConversationSeed where
  parseJSON = Aeson.withObject "ConversationSeed" \o ->
    ConversationSeed
      <$> o Aeson..:? "agentName" Aeson..!= ""
      <*> o Aeson..:? "turnsSoFar" Aeson..!= 0
      <*> o Aeson..:? "pendingMessage" Aeson..!= Nothing
      <*> o Aeson..:? "lastMessageId" Aeson..!= Nothing

-- | The seed generation 0 starts from, before any rotation has happened.
emptyConversationSeed :: ConversationSeed
emptyConversationSeed =
  ConversationSeed
    { agentName = "",
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

conversationWorkflowId :: AddressedMessage -> WorkflowId
conversationWorkflowId AddressedMessage {conversationId} =
  WorkflowId ("danwa-conversation:" <> conversationId)

runConversationTurn :: ConversationEnv -> AgentDecl -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
runConversationTurn env decl msg = do
  delivered <- deliverConversationInput env msg
  driveConversationTurn env msg conversationDriveBudget $
    if delivered then Nothing else Just (ConversationStart (name decl) msg)

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
  AddressedMessage ->
  Int ->
  Maybe ConversationStart ->
  IO (Either ConversationTurnFailure ConversationTurnResult)
driveConversationTurn env msg budget mStart = do
  outcomeE <- runConversationWorkflow env mStart msg
  case outcomeE of
    Left err -> pure (Left (ConversationTransientFailure (Text.pack (show err))))
    Right Failed -> pure (Left (ConversationTerminalFailure "conversation workflow failed"))
    Right Cancelled -> pure (Left (ConversationTerminalFailure "conversation workflow cancelled"))
    Right (Completed result) -> pure (first ConversationPermanentFailure result)
    Right Suspended -> completedTurn env msg
    Right ContinuedAsNew -> do
      loaded <- loadConversationResult env (conversationWorkflowId msg) (messageId msg)
      case loaded of
        Just result -> pure (Right result)
        Nothing
          | budget > 0 -> driveConversationTurn env msg (budget - 1) Nothing
          | otherwise ->
              pure
                ( Left
                    ( ConversationTransientFailure
                        ("conversation workflow kept rotating without recording a turn result for " <> messageId msg)
                    )
                )

-- | Read back the turn this run journaled.
completedTurn :: ConversationEnv -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
completedTurn env msg = do
  loaded <- loadConversationResult env (conversationWorkflowId msg) (messageId msg)
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
  turn <- processRotatingTurn env decl (initialMessage start)
  case turn of
    Left err -> pure (Left err)
    Right result -> do
      wake <- awaitConversationWake
      case wake of
        NextMessage next -> continueAsNew (nextConversationSeed seed start next)
        -- Nothing signals this yet -- the idle-timeout timer that does is the
        -- next milestone. Ending the epoch is already the right answer to it;
        -- what M3 adds in front of this is completing the kioku session.
        IdleTimedOut -> pure (Right result)

-- | The pre-rotation shape: one immortal generation, suffixed labels.
legacyConversation ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
legacyConversation env mStart = do
  start <- step (StepName "ingest-start") (ingestStart emptyConversationSeed mStart)
  decl <- resolveDeclStep env start
  firstResult <- processTurn env decl (initialMessage start)
  case firstResult of
    Left err -> pure (Left err)
    Right result -> loop env decl 1 result

-- | The one place the two entry paths meet.
--
-- Generation 0 of a fresh conversation is driven with an explicit
-- 'ConversationStart' payload. Every later generation is rotated into, so there
-- is no payload — the message to process rides on the seed instead, put there by
-- the rotation that closed the previous generation. Having neither means the
-- workflow was resumed before @ingest-start@ was ever journaled, which is not a
-- state the runtime can invent an answer for.
ingestStart :: (IOE :> es) => ConversationSeed -> Maybe ConversationStart -> Eff es ConversationStart
ingestStart ConversationSeed {agentName = seedAgentName, pendingMessage} mStart =
  case (pendingMessage, mStart) of
    (Just carried, _) -> pure (ConversationStart seedAgentName carried)
    (Nothing, Just start) -> pure start
    (Nothing, Nothing) ->
      liftIO (ioError (userError "danwa conversation workflow resumed before ingest-start was journaled"))

-- | The seed the next generation starts from.
nextConversationSeed :: ConversationSeed -> ConversationStart -> AddressedMessage -> ConversationSeed
nextConversationSeed ConversationSeed {turnsSoFar} ConversationStart {agentName = startAgentName, initialMessage = finished} next =
  ConversationSeed
    { agentName = startAgentName,
      turnsSoFar = turnsSoFar + 1,
      pendingMessage = Just next,
      lastMessageId = Just (messageId finished)
    }

-- | Park on the single declared await.
--
-- Allocation goes through the generated 'ConversationGenerated.nextMessageAwait'
-- binding rather than a hand-built 'StepName', so the label the runtime awaits
-- is the label @domain\/shikigami-conversation.keiro@ declares, by construction
-- rather than by agreement.
awaitConversationWake :: Eff (Workflow : AppEffects) ConversationWake
awaitConversationWake = do
  (_aid, awaitAnswer) <- ConversationGenerated.allocateDeclaredAwait ConversationGenerated.nextMessageAwait
  awaitAnswer

resolveDeclStep :: ConversationEnv -> ConversationStart -> Eff (Workflow : AppEffects) AgentDecl
resolveDeclStep env ConversationStart {agentName} =
  step (StepName "lookup-agent") do
    case find ((== agentName) . name) (agents env) of
      Just decl -> pure decl
      Nothing -> liftIO (ioError (userError ("unknown conversation agent " <> Text.unpack agentName)))

loop ::
  ConversationEnv ->
  AgentDecl ->
  Int ->
  ConversationTurnResult ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
loop env decl nextOrdinal _previous = do
  nextMessage <- awaitInput (nextMessageStepName nextOrdinal)
  result <- processTurn env decl nextMessage
  case result of
    Left err -> pure (Left err)
    Right completed -> loop env decl (nextOrdinal + 1) completed

processTurn ::
  ConversationEnv ->
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
processTurn env decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env decl msgConversationId))
  userTurn <-
    step (StepName ("record-user:" <> msgMessageId)) $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env decl sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
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
          assistantAndReplyE <- recordAssistantTurnAndEnqueueReply (grants env) decl sid msg replyText userTurnIndex turns
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
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
processRotatingTurn env decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env decl msgConversationId))
  userTurn <-
    step (StepName "record-user") $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env decl sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
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
          assistantAndReplyE <- recordAssistantTurnAndEnqueueReply (grants env) decl sid msg replyText userTurnIndex turns
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
  Maybe ConversationStart ->
  AddressedMessage ->
  IO (Either StoreError (WorkflowOutcome (Either Text ConversationTurnResult)))
runConversationWorkflow env mStart msg =
  let AppEnv {connectionSettings, tracer} = appEnv env
   in runEff
        . runTracing tracer
        . runErrorNoCallStack
        . withKirokuStore connectionSettings
        . runStoreResource
        $ runWorkflowWith
          shikigamiWorkflowRunOptions
          conversationWorkflowName
          (conversationWorkflowId msg)
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
deliverConversationInputFromApp appEnv' msg = do
  result <- runAppIO appEnv' do
    let wid = conversationWorkflowId msg
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
-- 3. Nothing exists, so a session is started (which writes the index).
resolveSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
resolveSession env decl conversationId = do
  indexedE <- runKioku env (SessionIndex.lookupConversationSession conversationId)
  case indexedE of
    Left err -> pure (Left (Text.pack (show err)))
    Right indexed -> do
      confirmed <- maybe (pure Nothing) (confirmIndexedSession env conversationId) indexed
      case confirmed of
        Just sid -> pure (Right sid)
        Nothing -> scanForConversationSession env decl conversationId

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
scanForConversationSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
scanForConversationSession env decl conversationId = do
  let scope = agentScope (name decl)
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
        Nothing -> startSession env decl conversationId

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

startSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
startSession env decl conversationId = do
  now <- getCurrentTime
  sid <- genSessionId
  result <-
    runKioku env $
      Session.start
        StartSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (name decl),
            ownerPrincipal = Nothing,
            agentId = name decl,
            focus = "conversation",
            scope = agentScope (name decl),
            subjectRef = Just conversationId,
            previousSessionId = Nothing,
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

recordTurnOnce :: ConversationEnv -> AgentDecl -> SessionId -> Text -> Maybe Int -> Text -> Text -> [TurnRow] -> IO RecordedTurn
recordTurnOnce env decl sid turnId desiredIndex role content turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex} -> pure RecordedTurn {turnId, turnIndex}
    Nothing -> do
      let turnIndex = fromMaybe (length turns) desiredIndex
      requireRight =<< recordTurn env decl sid turnId turnIndex role content
      pure RecordedTurn {turnId, turnIndex}

recordAssistantTurnAndEnqueueReply ::
  (IOE :> es, Store :> es, KirokuStoreResource :> es, Error StoreError :> es) =>
  GrantSource ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  Int ->
  [TurnRow] ->
  Eff es (Either Text (RecordedTurn, SinkResult))
recordAssistantTurnAndEnqueueReply grantSource decl sid msg@AddressedMessage {messageId = msgMessageId} replyText userTurnIndex turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex = existingTurnIndex} -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent grantSource decl sid msg replyText now)
      pure (Right (RecordedTurn {turnId, turnIndex = existingTurnIndex}, AgentWorkflow.preparedSinkResult prepared))
    Nothing -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent grantSource decl sid msg replyText now)
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
                  actorPrincipal = agentActor (name decl),
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
  GrantSource ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  UTCTime ->
  IO AgentWorkflow.PreparedSinkIntent
prepareConversationReplySinkIntent grantSource decl sid msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId} replyText now =
  AgentWorkflow.prepareSinkIntent
    grantSource
    (conversationWorkflowId msg)
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
    -- No resolved recipient: a conversation reply is a danwa sink, which has no
    -- recipientFrom strategy, and the turn was triggered by an addressed message
    -- rather than by an activity envelope.
    Nothing
    Agent.DanwaConversation {Agent.topic = "danwa-conversation"}
    (Aeson.object ["reply" Aeson..= replyText])
    now

recordTurn :: ConversationEnv -> AgentDecl -> SessionId -> Text -> Int -> Text -> Text -> IO (Either Text ())
recordTurn env decl sid turnId turnIndex role content = do
  now <- getCurrentTime
  result <-
    runKioku env $
      Session.recordTurn
        RecordTurnData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (name decl),
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
sinkResultDetail SinkResult {outcome = other} = Text.pack (show other)
