{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -O0 #-}

-- | The real path from a delivered envelope to a parked proposal: stream intake,
-- run queue, agent-run workflow, approval child and timers, with a counted stub
-- provider and a recording notifier. Shared by every initiative worker spec.
module Shikigami.Fixture.Proposing
  ( Proposing (..),
    Ask (..),
    Options (..),
    defaultOptions,
    withProposing,
    deliver,
    deliverBy,
    drain,
    settle,
    approve,
    reject,
    expire,
    CandidateRow (..),
    ProposalRow (..),
    candidates,
    proposals,
    objectives,
    agentPrincipal,
    proposerIdentity,
    coordinatorIdentity,
    PolicyTerms (..),
    defaultTerms,
    installTerms,
    runTx,
    policyContext,
    plainReport,
    repositoryIds,
    settingsWith,
    count,
    stepNames,
    stepValue,
    flowOriginLabels,
    humanActor,
    agentActorFixture,
  )
where

import Baikai.Options qualified as BaikaiOptions
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.Stream (liftCompleteToStream)
import Control.Lens ((&), (.~))
import Control.Monad (forM, replicateM_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent)
import Keiro.Workflow (loadStepIndex)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Resume (defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers)
import Keiro.Workflow.Types (WorkflowOutcome)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Pgmq (Message (..), MessageBody (..), ReadMessage (..), readMessage)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Approval (ApprovalChannel, ApprovalDecision (..), ApprovalRequest (..), approvalTimeoutFireAction, autoApprovePolicy, resolveApproval)
import Shikigami.Agent.Approval.Notification (renderApprovalMessage)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), defaultDelegationBudget)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Agent.Run (AgentRunResult)
import Shikigami.Agent.RunFailure (AgentRunFailure)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), defaultAppConfig)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Provider qualified as CapabilityProvider
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Directory qualified as Directory
import Shikigami.Duration (Duration, durationTime, parseDuration, remainingDuration)
import Shikigami.Execution.Policy.Types (defaultHarnessPolicy)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Initiative qualified as FlowInitiative
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Initiative.Policy qualified as Policy
import Shikigami.Initiative.Settings (InitiativeSettings)
import Shikigami.Initiative.Types (ActionClass (..), SourceKind (..))
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Types qualified as Objective
import Shikigami.PracticeReview.Capability qualified as Practice
import Shikigami.Repository (RepositoryId, repositoryId)
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Sink (GrantSource (StaticGrants), SinkKind (SKizashiSignal), defaultGrantTable)
import Shikigami.Sink.Config
import Shikigami.Sink.Http (HttpLimits (..), SinkHttp, credentialsFromConfig, newSinkHttp)
import Shikigami.Trigger.Consumer (RecordDisposition, processDecodedActivityObserving)
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors))
import Test.Tasty.HUnit (assertFailure)

-- | One ask the notifier was handed, with the deadline its timer was armed at.
data Ask = Ask
  { message :: !Text,
    deadline :: !(Duration "approval"),
    channel :: !ApprovalChannel,
    context :: !Value,
    token :: !AwakeableId
  }

data Options = Options
  { evaluationsPerWindow :: !Int,
    proposalsPerWindow :: !Int,
    notificationsPerWindow :: !Int,
    evaluationCutoffSeconds :: !Int,
    suppressionSeconds :: !Int,
    creationGranted :: !Bool
  }

defaultOptions :: Options
defaultOptions =
  Options
    { evaluationsPerWindow = 50,
      proposalsPerWindow = 50,
      notificationsPerWindow = 50,
      evaluationCutoffSeconds = 3600,
      suppressionSeconds = 604800,
      creationGranted = True
    }

data Proposing = Proposing
  { env :: !AppEnv,
    pool :: !Pool.Pool,
    deps :: !Agent.AgentRunDeps,
    settings :: !InitiativeSettings,
    directory :: !Directory.DirectoryHandle,
    declaration :: !AgentDecl,
    coordinator :: !AgentDecl,
    objectiveRuntime :: !Objectives.ObjectiveRuntime,
    calls :: !(IO Int),
    asks :: !(IO [Ask])
  }

agentPrincipal :: AgentPrincipal
agentPrincipal = either (error . Text.unpack) id (mkAgentPrincipal "agent_shikigami_proposer")

proposerIdentity :: AgentIdentity
proposerIdentity = VerifiedIdentity agentPrincipal

coordinatorPrincipal :: AgentPrincipal
coordinatorPrincipal = either (error . Text.unpack) id (mkAgentPrincipal "agent_shikigami_coordinator")

coordinatorIdentity :: AgentIdentity
coordinatorIdentity = VerifiedIdentity coordinatorPrincipal

repositoryIds :: [RepositoryId]
repositoryIds = [repositoryId "repo_payments", repositoryId "repo_billing"]

plainReport :: Text
plainReport = "Double-clicking checkout charges the card twice on every attempt"

settingsWith :: Options -> InitiativeSettings
settingsWith options =
  either error id . Aeson.eitherDecode . Aeson.encode $
    object
      [ "observers"
          .= [ object
                 [ "principal" .= ("agent_shikigami_proposer" :: Text),
                   "sources" .= (["chat-fixture"] :: [Text]),
                   "minimumExcerptLength" .= (20 :: Int),
                   "evaluation"
                     .= object
                       [ "limits"
                           .= object
                             [ "ActiveWork" .= (1 :: Int),
                               "ModelAttempts" .= (2 :: Int),
                               "Tokens" .= ("unbounded" :: Text),
                               "CostMicroUsd" .= ("unbounded" :: Text)
                             ],
                         "cutoff" .= options.evaluationCutoffSeconds
                       ],
                   "evaluationsPerWindow" .= options.evaluationsPerWindow,
                   "proposalsPerWindow" .= options.proposalsPerWindow,
                   "notificationsPerWindow" .= options.notificationsPerWindow,
                   "window" .= (3600 :: Int),
                   "proposalExpiry" .= (86400 :: Int),
                   "rejectionSuppression" .= options.suppressionSeconds,
                   "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                 ]
             ]
      ]

withProposing :: DatabaseFixture -> Options -> (Proposing -> IO a) -> IO a
withProposing fixture options use = withShikigamiFreshDatabase fixture \connection ->
  withStore (defaultConnectionSettings connection) \store -> do
    tracer <- noopTracer
    behavior <- newBehaviorEnv
    declaration <- either (assertFailure . show) pure =<< loadAgent "../agents/proof/proposer.dhall"
    coordinatorDeclaration <- either (assertFailure . show) pure =<< loadAgent "../agents/proof/adaptive-delivery.dhall"
    counted <- newIORef (0 :: Int)
    recorded <- newIORef []
    directory <-
      Directory.newDirectoryHandle
        ( Directory.staticDirectorySource
            [ Directory.PrincipalRecord (declarationCoordinate "agent_shikigami_proposer") (declarationCoordinate "proposer") Directory.Active,
              Directory.PrincipalRecord (declarationCoordinate "agent_shikigami_coordinator") (declarationCoordinate "adaptive-delivery") Directory.Active
            ]
        )
    Directory.refreshDirectory directory >>= either (assertFailure . Text.unpack) pure
    http <- either (assertFailure . show) pure =<< newSinkHttp (HttpLimits defaultAppConfig.httpRequestMaxBytes defaultAppConfig.httpResponseMaxBytes) (credentialsFromConfig defaultAppConfig) (DanwaConfig "http://localhost:1" (declarationCoordinate "fixture"))
    let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
        provider =
          decisionStubProvider
            & #complete .~ completing
            & #stream .~ liftCompleteToStream completing
        completing model context callOptions = do
          modifyIORef' counted (+ 1)
          decisionStubProvider.complete model context callOptions
        binding = either (error . show) id (modelBinding Decision.proposeAlias "1" "propose" "1" (stubModel & #modelId .~ "stub-propose") BaikaiOptions.emptyOptions Nothing)
        settings = settingsWith options
        objectiveSettings =
          Objective.defaultObjectiveSettings
            & #enabled .~ Objective.ObjectivesEnabled
            & #agentCreation .~ [agentPrincipal | options.creationGranted]
        objectiveRuntime = Objectives.ObjectiveRuntime env objectiveSettings directory allowAllActionAuthorizerForTests Nothing
        coordinator = coordinatorDeclaration & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_shikigami_coordinator"))
        deps = proposingDeps env behavior provider binding objectiveRuntime settings repositoryOptions [declaration, coordinator] http directory store.pool recorded
        repositoryOptions = [FlowInitiative.RepositoryOption identifier "fixture repository" | identifier <- repositoryIds]
    _ <- either (assertFailure . show) pure =<< ensureRunQueue store.pool
    _ <- either (assertFailure . show) pure =<< runAppIO env Catalog.registerProjectionCatalog
    use
      Proposing
        { env,
          pool = store.pool,
          deps,
          settings,
          directory,
          declaration,
          coordinator,
          objectiveRuntime,
          calls = readIORef counted,
          asks = reverse <$> readIORef recorded
        }

-- | This module is compiled at -O0 because constructing this record here under
-- optimization crashes the collector (FRIC-60); the cause is not established.
proposingDeps ::
  AppEnv ->
  BehaviorEnv ->
  ApiProvider ->
  ModelBinding ->
  Objectives.ObjectiveRuntime ->
  InitiativeSettings ->
  [FlowInitiative.RepositoryOption] ->
  [AgentDecl] ->
  SinkHttp ->
  Directory.DirectoryHandle ->
  Pool.Pool ->
  IORef [Ask] ->
  Agent.AgentRunDeps
proposingDeps env behavior provider binding objectiveRuntime settings repositoryOptions declarations http directory pool recorded =
  Agent.AgentRunDeps
    { appEnv = env,
      behaviorEnv = behavior,
      decisions = Decision.defaultDecisionServices (either (error . show) id (modelCatalog [binding])) & #providers .~ [provider],
      actionAuthorizer = allowAllActionAuthorizerForTests,
      capabilities = CapabilityProvider.emptyCapabilityRuntime,
      workspace = Nothing,
      coordination = Nothing,
      objectives = Just objectiveRuntime,
      initiatives =
        FlowInitiative.InitiativeSeed
          { settings = Just settings,
            repositories = repositoryOptions,
            hooks = FlowInitiative.noInitiativeHooks
          },
      agents = declarations,
      kizashi = KizashiConfig "http://localhost:1" (declarationCoordinate "recipient"),
      kawa = KawaConfig "http://localhost:1" (activityCoordinate "fixture"),
      kanmon = KanmonConfig "http://localhost:1",
      danwa = DanwaConfig "http://localhost:1" (declarationCoordinate "fixture"),
      rei = ReiConfig Nothing,
      http,
      hooks = Agent.defaultAgentRunHooks,
      approvalPolicy = autoApprovePolicy (either (error . show) id (parseDuration 900)),
      approvalWorkflow = Approval.ApprovalWorkflowEnv {notifier = recordingNotifier recorded},
      runTimeout = either (error . show) id (parseDuration 30),
      harness = defaultHarnessPolicy,
      delegationBudget = defaultDelegationBudget,
      grants = StaticGrants (Map.insert proposerIdentity (Set.singleton SKizashiSignal) defaultGrantTable),
      directory,
      routing = Routing.RoutingRuntime (\_ -> error "no router") (\_ _ _ -> error "no router"),
      practiceReview = Practice.unavailablePracticeReviewRuntime,
      deliveryPool = Just pool,
      logger = Log.silentLogger,
      resolveRunProfile = \profile version -> pure (Left (UnknownProfile profile version))
    }

recordingNotifier :: IORef [Ask] -> Approval.ApprovalNotifier
recordingNotifier recorded =
  Approval.ApprovalNotifier
    { recordPark = \_ _ _ _ -> pure (),
      postAsk = \review awakeable deadline request -> do
        modifyIORef'
          recorded
          ( Ask
              { message = renderApprovalMessage review awakeable deadline request,
                deadline,
                channel = request.channel,
                context = request.context,
                token = awakeable
              }
              :
          )
        pure (Right ())
    }

-- | The terms of a standing policy a spec varies.
data PolicyTerms = PolicyTerms
  { sources :: ![SourceKind],
    repositories :: ![RepositoryId],
    actionClasses :: ![ActionClass],
    perObjectiveAttempts :: !Integer,
    totalAttempts :: !Integer,
    admissionsPerWindow :: !Int,
    lifetimeSeconds :: !NominalDiffTime
  }

defaultTerms :: PolicyTerms
defaultTerms =
  PolicyTerms
    { sources = [ChatFixture],
      repositories = [head repositoryIds],
      actionClasses = [ReproduceAndDiagnose],
      perObjectiveAttempts = 2,
      totalAttempts = 20,
      admissionsPerWindow = 10,
      lifetimeSeconds = 86400
    }

policyContext :: Proposing -> UTCTime -> Policy.PolicyContext
policyContext fixture now =
  Policy.PolicyContext
    { principalActive = const True,
      objectives = fixture.objectiveRuntime.settings,
      catalog = repositoryIds,
      declarations = [fixture.declaration, fixture.coordinator],
      now,
      maximumLifetime = remainingDuration (30 * 24 * 60 * 60)
    }

installTerms :: Proposing -> PolicyTerms -> IO Policy.StandingPolicy
installTerms fixture terms = do
  now <- getCurrentTime
  let document =
        object
          [ "principal" .= principalText agentPrincipal,
            "sources" .= terms.sources,
            "repositories" .= terms.repositories,
            "actionClasses" .= terms.actionClasses,
            "coordinator" .= fixture.coordinator.name,
            "perObjective" .= object ["ActiveWork" .= (2 :: Int), "ModelAttempts" .= terms.perObjectiveAttempts, "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)],
            "objectiveWindow" .= (7200 :: Int),
            "total" .= object ["ActiveWork" .= (1000 :: Int), "ModelAttempts" .= terms.totalAttempts, "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)],
            "admissionsPerWindow" .= terms.admissionsPerWindow,
            "window" .= (3600 :: Int),
            "expiresAt" .= addUTCTime terms.lifetimeSeconds now
          ]
      operator = either (error . Text.unpack) id (Objective.parseOperatorId "local-operator")
  input <- either assertFailure pure (Aeson.eitherDecode (Aeson.encode document))
  runAppIO fixture.env (Policy.installPolicy operator (policyContext fixture now) input)
    >>= either (assertFailure . show) (either (assertFailure . show) pure)

runTx :: Proposing -> Tx.Transaction value -> IO value
runTx fixture transaction = runAppIO fixture.env (runTransaction transaction) >>= either (assertFailure . show) pure

-- | Deliver one chat message through the stream consumer.
deliver :: Proposing -> Text -> Text -> Text -> IO RecordDisposition
deliver fixture activity subject = deliverBy fixture humanActor "fixture/chat" activity subject

deliverBy :: Proposing -> Actor -> Text -> Text -> Text -> Text -> IO RecordDisposition
deliverBy fixture actor source activity subject body =
  processDecodedActivityObserving
    Log.silentLogger
    fixture.env
    fixture.directory
    (Just fixture.settings)
    ExcludeAgentActors
    [fixture.declaration]
    (const (pure ()))
    (chatEvent actor source activity subject body)
    Nothing

humanActor :: Actor
humanActor = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing}

agentActorFixture :: Actor
agentActorFixture = Actor {kind = AgentActor, id = activityCoordinate "agent_other", session = Nothing}

chatEvent :: Actor -> Text -> Text -> Text -> Text -> IntegrationEvent
chatEvent actor source activity subject body =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId = "message-" <> activity,
        source = "shinzui/test",
        destination = "activity.v1",
        key = Just subject,
        eventType = "activity.recorded",
        schemaVersion = 1,
        contentType = ApplicationJson,
        schemaReference = Nothing,
        sourceEventId = Nothing,
        sourceGlobalPosition = Nothing,
        payloadBytes = mempty,
        occurredAt = UTCTime (fromGregorian 2026 11 4) 0,
        causationId = Nothing,
        correlationId = Nothing,
        traceContext = Nothing,
        attributes = Nothing
      }
    ActivityEnvelope
      { activityId = activityCoordinate activity,
        occurredAt = activityCoordinate "2026-11-04T00:00:00Z",
        source = activityCoordinate source,
        actor,
        subject = Subject {kind = activityCoordinate "chat", subjectId = activityCoordinate subject},
        verb = activityCoordinate "message.created",
        payload = object ["text" .= body],
        contextRefs = [],
        idempotencyKey = activityCoordinate activity
      }

-- | Run every job on the queue once, as a worker would, leaving each invisible so
-- only new work is drained next time.
drain :: Proposing -> IO [(RunJob, Either StoreError (WorkflowOutcome (Either AgentRunFailure AgentRunResult)))]
drain fixture = do
  messages <-
    Pool.use fixture.pool (readMessage ReadMessage {queueName = runQueueName, delay = 3600, batchSize = Just 20, conditional = Nothing})
      >>= either (assertFailure . show) pure
  forM (Vector.toList messages) \Message {body = MessageBody payload} -> do
    job <- either (assertFailure . show) pure (RunJobs.decodeRunJob payload)
    outcome <- Agent.runAgentRunWorkflow fixture.deps job
    pure (job, outcome)

-- | Drive every parked or resumable workflow until the journals stop moving.
settle :: Proposing -> IO ()
settle fixture =
  replicateM_ 3 do
    runAppIO fixture.env (resumeWorkflowsOnce defaultWorkflowResumeOptions (Agent.agentRunRegistry fixture.deps))
      >>= either (assertFailure . show) (const (pure ()))

approve :: Proposing -> Ask -> IO ()
approve fixture ask = do
  answered <- resolveApproval fixture.env ask.token (Approved (object ["approved" .= True]))
  if answered then settle fixture else assertFailure "the approval was already answered"

reject :: Proposing -> Ask -> Text -> IO ()
reject fixture ask reason = do
  answered <- resolveApproval fixture.env ask.token (Rejected reason)
  if answered then settle fixture else assertFailure "the approval was already answered"

-- | Fire due durable timers as if the approval's deadline had passed, as the
-- scheduler's drain does. A session's idle timer is also due by then, and this
-- action does not claim it, so a single-claim worker would only ever see that one.
expire :: Proposing -> Ask -> IO ()
expire fixture ask = do
  now <- getCurrentTime
  let past :: NominalDiffTime
      past = durationTime ask.deadline + 2
  fired <- runAppIO fixture.env (drainWorkflowSleepTimers Nothing (addUTCTime past now) 20 approvalTimeoutFireAction) >>= either (assertFailure . show) pure
  if fired > 0 then settle fixture else assertFailure "no timer was due at the proposal's expiry"

data CandidateRow = CandidateRow
  { activity :: !Text,
    verdict :: !Text,
    skipReason :: !(Maybe Text),
    subject :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

candidates :: Proposing -> IO [CandidateRow]
candidates fixture =
  Pool.use fixture.pool (Session.statement () statement) >>= either (assertFailure . show) pure
  where
    statement =
      preparable
        "SELECT activity_id,verdict,skip_reason,subject_id FROM shikigami.initiative_candidates ORDER BY recorded_at,activity_id"
        E.noParams
        (D.rowList (CandidateRow <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text) <*> D.column (D.nullable D.text)))

data ProposalRow = ProposalRow
  { proposalId :: !Text,
    status :: !Text,
    statusDetail :: !Value,
    assessment :: !Value,
    suppressedUntil :: !(Maybe UTCTime),
    resolvedAt :: !(Maybe UTCTime),
    revision :: !Int
  }
  deriving stock (Eq, Show)

proposals :: Proposing -> IO [ProposalRow]
proposals fixture =
  Pool.use fixture.pool (Session.statement () statement) >>= either (assertFailure . show) pure
  where
    statement =
      preparable
        "SELECT proposal_id,status,status_detail,assessment,suppressed_until,resolved_at,revision::bigint FROM shikigami.initiative_proposals ORDER BY proposed_at,proposal_id"
        E.noParams
        ( D.rowList
            ( ProposalRow
                <$> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.jsonb)
                <*> D.column (D.nonNullable D.jsonb)
                <*> D.column (D.nullable D.timestamptz)
                <*> D.column (D.nullable D.timestamptz)
                <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
            )
        )

objectives :: Proposing -> IO [Objective.Objective]
objectives fixture = do
  rows <- Pool.use fixture.pool (Session.statement () statement) >>= either (assertFailure . show) pure
  forM rows \value -> case Aeson.fromJSON value of
    Aeson.Success objective -> pure objective
    Aeson.Error problem -> assertFailure problem
  where
    statement = preparable "SELECT state FROM shikigami.objectives" E.noParams (D.rowList (D.column (D.nonNullable D.jsonb)))

count :: Proposing -> Text -> IO Int
count fixture table =
  Pool.use fixture.pool (Session.statement () statement) >>= either (assertFailure . show) (pure . fromIntegral)
  where
    statement = preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))

stepValue :: Proposing -> RunJob -> Text -> IO Value
stepValue fixture job name = do
  index <- runAppIO fixture.env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0) >>= either (assertFailure . show) pure
  maybe (assertFailure ("step not journaled: " <> Text.unpack name)) pure (Map.lookup name index)

-- | The trusted origin rows objective creation recorded.
flowOriginLabels :: Proposing -> IO [Text]
flowOriginLabels fixture =
  Pool.use fixture.pool (Session.statement () statement) >>= either (assertFailure . show) pure
  where
    statement = preparable "SELECT origin->>'label' FROM shikigami.objective_origins" E.noParams (D.rowList (D.column (D.nonNullable D.text)))

stepNames :: Proposing -> RunJob -> IO [Text]
stepNames fixture job =
  runAppIO fixture.env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
    >>= either (assertFailure . show) (pure . Map.keys)
