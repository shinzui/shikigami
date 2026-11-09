{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

-- The native adaptive controller, real continuing workers, configured mutable
-- host, accepted tools and objective owner. Scripted stages replace model
-- responses and the C13 issuer; explicit live stages use production composition.
module Adaptive (adaptiveCase, adaptiveContract, livePreflight, liveControls) where

import Accepted (Prepared (..), continueTools, prepareToolsFor)
import Baikai.Api (Api (..))
import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Cost qualified as Cost
import Baikai.Evidence qualified as Evidence
import Baikai.Message qualified as Message
import Baikai.Model qualified as Model
import Baikai.Options (emptyOptions)
import Baikai.Options qualified as Options
import Baikai.Provider.Registry qualified as Provider
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Usage qualified as Usage
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful.Dispatch.Static (unsafeEff_)
import FixtureIdentity (fixtureAttemptId, fixtureOperationId, fixtureRootId)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow qualified as W
import Keiro.Workflow.Resume (WorkflowDef (..), resumeWorkflowsOnce)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Qualification (Qualification (..), Ready (..), right, run, runTools, successful, withQualification)
import Shikigami.Action.Authorization (ActionAuthorizationDecision (..), ActionAuthorizer (..))
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Activity.Coordinate
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Decl
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Agent.RunJob
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey (parseRequestKey)
import Shikigami.App (AppEnv (..))
import Shikigami.App.Config
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), runAppConfig)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Provider (newBehaviorEnvFor, providerCallFor, validateProviderSelection)
import Shikigami.Behavior.Provider.Coordinate (providerCoordinateText)
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Behavior.StubProvider (stubApiProvider, stubModel)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), emptyResolvedCapabilitySet)
import Shikigami.Coordination.Checkpoint qualified as CP
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types (Admission (..))
import Shikigami.Coordination.Workflow qualified as Adaptive
import Shikigami.Decision.Contract (DecisionFailure, ModelDescriptor (..), PreparedDecision (..), modelAliasText, modelRegistrationText, parseModelAlias, versionedDigest)
import Shikigami.Decision.ModelCatalog (ModelCatalog, bindingCredential, bindingModel, bindingOptions, catalogDescriptors, modelBinding, modelCatalog, pinnedBinding)
import Shikigami.Decision.ModelCatalog qualified as Models
import Shikigami.Directory qualified as Directory
import Shikigami.Duration
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Coordinate (executionCoordinate, executionCoordinateText)
import Shikigami.Execution.Counter (attemptNumber, noAttempts)
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity (ExecutionRootId, parseOperationId)
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Quantity (amountUnits, parseResourceAmount)
import Shikigami.Execution.Request (ExecutionPolicy (..), ExecutionRequest (..))
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Selection (defaultBinding, resolveExecutionSelection)
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as ExecutionDriver
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Initiative qualified as Initiative
import Shikigami.Flow.Observe qualified as Observe
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Log qualified as Log
import Shikigami.Objective.Acceptance (validateAcceptance, validateGraph)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Types
import Shikigami.PracticeReview.Capability qualified as Practice
import Shikigami.Prelude ((%~), (&), (.~))
import Shikigami.Program.Decision.Adaptive (AdaptiveInput (..))
import Shikigami.Repository (RepositoryId, repositoryId)
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config
import Shikigami.Sink.Http (HttpLimits (..), credentialsFromConfig, newSinkHttp)
import Shikigami.Trigger.Enqueue (addressedRunJob, ensureRunQueue)
import Shikigami.WorkerSession.Capability qualified as Workers
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Store qualified as SessionStore
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types qualified as WS
import Shikigami.WorkerSession.Workflow qualified as Sessions
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation (workspaceMetadata)
import Shikigami.Workspace.ConfiguredHost
import Shikigami.Workspace.FileProvider (supervisedWorkspaceEditDescriptor)
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitProvider (workspaceGitDescriptor)
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Integration qualified as Integration
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Profile (retainedProcessRule)
import Shikigami.Workspace.Provider (Replacement (..), contentDigest)
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Supervisor (SupervisorRuntime (..), systemdSupervisorBackend, workspaceExecDescriptor)
import Shikigami.Workspace.Transfer qualified as WorkspaceOwner
import Shikigami.Workspace.TransferClient (workspaceTransferClient)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import Shikumi.Tool qualified as Tool
import Shikumi.Tool.Output (ToolOutput (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Process (exitImmediately)
import System.Process (callProcess, proc, readCreateProcessWithExitCode, readProcess, readProcessWithExitCode)
import System.Process qualified as Process
import System.Timeout (timeout)

data Saved = Saved {objectiveId :: !ObjectiveId, job :: !RunJob}
  deriving stock (Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

data UnknownCut = UnknownCut {reference :: !Attempt.JobReference, identity :: !AgentIdentity, admission :: !WorkspaceAdmission}
  deriving stock (Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

data Repo = Repo {name :: !Text, repository :: !RepositoryId, source :: !FilePath, base :: !(WorkspaceCoordinate "git-object"), bundle :: !InstructionBundle}

names :: [Text]
names = ["producer", "producer-review", "consumer", "consumer-review"]

actor :: Text -> AgentIdentity
actor = VerifiedIdentity . checked . mkAgentPrincipal . ("agent_01h000000000000000" <>)

agent :: Text -> AgentName
agent = checked . mkAgentName

key :: Text -> ObjectiveAssignmentId
key = checked . parseObjectiveAssignmentId

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

json :: (Aeson.ToJSON a) => a -> Text
json = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode

initialAssignment :: AssignmentDraft
initialAssignment = AssignmentDraft (key "delivery") (checked (parseInstructions "Deliver a verified finite pair")) [] (actor "coordinator") Pending Nothing Nothing Nothing

adaptiveContract :: IO ()
adaptiveContract = do
  either (fail . show) pure (validateGraph [initialAssignment])
  putStrLn "PASS native adaptive initial assignment is valid before root/cutoff admission"

adaptiveCase :: FilePath -> FilePath -> String -> IO ()
adaptiveCase config prefix requestedStage = withQualification config prefix \original -> withStore original.env.connectionSettings \store -> do
  liveSettings <- if "-live" `Text.isSuffixOf` Text.pack requestedStage then Just <$> readLiveSettings (prefix </> "live-limits.json") else pure Nothing
  directory <- right =<< Directory.startDirectory Log.silentLogger original.config.directorySettings
  let live = isJust liveSettings
      stageText = fromMaybe (Text.pack requestedStage) (Text.stripSuffix "-live" (Text.pack requestedStage))
      transferring = "-transfer" `Text.isSuffixOf` stageText
      stage = Text.unpack (fromMaybe stageText (Text.stripSuffix "-transfer" stageText))
      fixtureWorkers = names <> ["consumer-successor" | transferring]
      env = original.env & #store .~ Just store
      q = original & #env .~ env & #authorizer .~ (if live then recordAuthority prefix original.authorizer else original.authorizer)
      settings = defaultObjectiveSettings & #enabled .~ ObjectivesEnabled
      own = key "delivery"
      callerName = if live then case q.config.actionAuthorization of KikanActionAuthorization {callerId} -> callerId; _ -> error "live authority absent" else "workspace-fixture"
      caller = checked (parseCallerId callerName)
      owner = O.ObjectiveHost settings (pure (Right (VerifiedCaller caller))) q.authorizer (\_ _ -> pure (Left ObjectiveDenied)) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))
      command goal operation change = do
        retained <- right =<< run env (O.readCommandReceipt owner goal (fixtureOperationId operation))
        case retained of
          Just result -> right result
          Nothing -> do
            current <- right =<< run env (O.readObjective owner goal)
            outcome <- run env (O.executeCommand owner goal current.revision (fixtureOperationId operation) change)
            either (fail . (("native objective command " <> Text.unpack operation <> " refused: ") <>) . show) pure outcome
  void (right =<< run env Catalog.registerProjectionCatalog)
  repos <- forM ["producer", "consumer"] \name -> do
    let source = prefix </> "adaptive-repositories" </> Text.unpack name
    base <- workspaceCoordinate . Text.strip . Encoding.decodeUtf8 <$> (right =<< runWorkspaceGit prefix 65536 ["-C", source, "rev-parse", "HEAD"])
    instructions <- Encoding.decodeUtf8 <$> Bytes.readFile (source </> "AGENTS.md")
    let repository = repositoryId ("mori://fixture/adaptive-" <> name)
        bundle = checked (mkInstructionBundle 65536 repository base [(workspaceCoordinate "AGENTS.md", instructions)])
    pure (Repo name repository source base bundle)
  let repositoryFor name = fromMaybe (error "fixture repository") (find (\repo -> repo.name `Text.isPrefixOf` name) repos)
      policy repo = checked (mkProcessPolicy (ProcessPolicyInput ProcessPolicyV1 q.initial.profile.policy.image q.initial.profile.policy.propertiesDigest [checked (mkCommandRule (CommandRuleInput (workspaceCoordinate "validate") (workspaceCoordinate "/bin/adaptive-check") [workspaceCoordinate repo.name] (workspaceCoordinate "") Map.empty (checked (parseProcessSeconds 5)) (checked (parseProcessOutputBytes 1024))))] [workspaceCoordinate ""] [workspaceCoordinate ""]))
      repositories = [WorkspaceRepository repo.repository (workspaceLocator repo.source) [WorkspaceRevision repo.base (bundleDigest repo.bundle)] repo.base (workspaceCoordinate "adaptive-reviewed/1") [workspaceCoordinate ""] [workspaceCoordinate ""] | repo <- repos]
      process = fromMaybe (error "native process settings") (q.config.workspaceSettings >>= (.process))
      workspaceSettings = WorkspaceSettings q.initial.binding.storageRoot repositories [WorkspaceGrant (agent name) (declarationCoordinate ("agent_01h000000000000000" <> if "integrate-" `Text.isPrefixOf` name then "coordinator" else name)) (repositoryFor (Text.replace "integrate-" "" name)).repository Nothing | name <- fixtureWorkers <> ["integrate-producer", "integrate-consumer"]] (Just (process & #policies .~ Map.fromList [(repo.repository, policy repo) | repo <- repos]))
  nativeHost <- right (configuredWorkspaceHostWithTransfers env store.pool directory.handle q.authorizer workspaceSettings)
  when live do
    templateBytes <- Bytes.readFile "/var/lib/shikigami-workspace-fixture-code/tests/adaptive-delivery/live-skill/SKILL.md"
    createDirectoryIfMissing True (prefix </> "live-skill")
    let contents = ["pending\n", "{\"version\":1,\"path\":[\"text\"]}\n"] :: [Text]
        context = Aeson.object ["repositories" .= [Aeson.object ["role" .= repo.name, "base" .= repo.base] | repo <- repos], "initialContents" .= [Aeson.object ["text" .= text, "expected" .= contentDigest text] | text <- contents]]
    Bytes.writeFile (prefix </> "live-skill/SKILL.md") (templateBytes <> "\nTrusted starting repository context:\n\n" <> Encoding.encodeUtf8 (json context))
  template <- right =<< loadAgent "/var/lib/shikigami-workspace-fixture-code/agents/triage-note.dhall"
  liveCatalog <- traverse (\limits -> validateLiveConfig q.config limits ("adaptive" : names)) liveSettings
  let alias name = checked (parseModelAlias name)
      rolePolicy name = ExecutionPolicy (alias name) [alias name]
      worker name = template & #name .~ agent name & #identity .~ Just (IdentityDecl (declarationCoordinate ("agent_01h000000000000000" <> name))) & #behavior .~ Skill (declarationCoordinate (if live then Text.pack (prefix </> "live-skill") else "/var/lib/shikigami-workspace-fixture-code/agents/skills/triage-note")) & #execution .~ Just (rolePolicy name) & #capabilityOverlays .~ map (.capability) [supervisedWorkspaceEditDescriptor, workspaceExecDescriptor, workspaceGitDescriptor] & #sinks .~ [] & #memory . #recordPolicy .~ Never
      workers = map worker fixtureWorkers
      root = template & #description .~ (if live then liveCoordinatorInstructions else template.description) & #name .~ agent "coordinator" & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_01h000000000000000coordinator")) & #behavior .~ Flow (declarationCoordinate "adaptive-delivery") & #delegates .~ map (.name) workers & #decisionModels .~ [alias "adaptive"] & #execution .~ Just (ExecutionPolicy (alias "adaptive") (map alias ("adaptive" : fixtureWorkers))) & #sinks .~ [] & #memory . #recordPolicy .~ Never
      declarations = root : workers
      catalog = fromMaybe (checked (modelCatalog [checked (modelBinding (alias name) "1" ("adaptive-fixture-" <> name) "1" (stubModel & #modelId .~ name) emptyOptions Nothing) | name <- "adaptive" : fixtureWorkers])) liveCatalog
      baseSessions = Objectives.coordinationHost env settings directory.handle q.authorizer declarations defaultDelegationBudget (Just (workspaceTransferClient q.client))
      -- Receipt publication is paused at the unknown cut. Invoke the same real
      -- owner with directory authority, factual policy lookup and OS locks;
      -- the paused listener cannot supply a meaningful admission refusal.
      independentFence = WorkspaceOwner.workspaceTransferProvider (SupervisorRuntime env q.authorizer (Directory.identityLifecycleAdmission directory.handle) q.current (retainedProcessRule env) systemdSupervisorBackend)
      loseOwnership :: Transfer.OwnershipProvider -> Transfer.OwnershipProvider
      loseOwnership provider = Transfer.OwnershipProvider \intent proof -> do
        outcome <- provider.transfer intent proof
        case outcome of
          Transfer.OwnershipAccepted receipt | transferring && stage == "ownership-crash" -> do
            unless (Transfer.matchesOwnership intent proof receipt) (fail "native ownership receipt changed")
            Just (pending, _) <- right =<< run env (SessionStore.inspectSession intent.sessionId)
            reference <- right =<< run env (O.resolveAssignment (q.objectives (actor "coordinator")) intent.objective)
            goal <- right =<< run env (O.readObjective (q.objectives (actor "coordinator")) reference.objectiveId)
            assignment <- maybe (fail "transferred objective assignment missing") pure (find ((== reference.assignmentId) . (.definition.assignmentId)) goal.assignments)
            unless (pending.owner == intent.oldOwner && pending.epoch == intent.oldEpoch && assignment.definition.owner == intent.newOwner && assignment.ownerEpoch == intent.newEpoch) (fail "ownership cut is not between objective commit and local establishment")
            let fence = workspaceTransferClient q.client
            oldWrite <- fence.admitWrite intent.workspace intent.sessionId intent.oldOwner intent.oldEpoch (fixtureOperationId "adaptive-fenced-old-write")
            earlyWrite <- fence.admitWrite intent.workspace intent.sessionId intent.newOwner intent.newEpoch (fixtureOperationId "adaptive-unestablished-successor-write")
            unless (either (const True) (const False) oldWrite && either (const True) (const False) earlyWrite) (fail "unestablished ownership admitted a write")
            Lazy.writeFile (prefix </> "adaptive-ownership-crashed.json") (Aeson.encode (Aeson.object ["intent" .= intent, "fence" .= proof, "receipt" .= receipt, "sessionOwner" .= pending.owner, "sessionEpoch" .= pending.epoch, "assignment" .= assignment, "oldWriteDenied" .= True, "earlySuccessorWriteDenied" .= True]))
            exitImmediately (ExitFailure 91)
          _ -> pure outcome
      sessions = baseSessions & #services %~ (\services -> services & #ownership %~ fmap loseOwnership)
      objectives = Objectives.ObjectiveRuntime env settings directory.handle q.authorizer (Just sessions)
      criterion = checked (parseCriterionKey "combined-journey")
      evidenceKey = checked (parseEvidenceKey "exact-pair-journey")
  saved <-
    if stage == "admit"
      then do
        void (right =<< ensureRunQueue store.pool)
        created <- right =<< run env (O.createObjective owner (fixtureOperationId "adaptive-delivery-create") Nothing (CreateRequest (checked (parseTitle "Finite two repository delivery")) (checked (parseGoal "Deliver hello across producer and consumer")) (checked (parseInstructions "Reconcile schema findings through the same worker session; require the exact integrated pair")) [Criterion criterion (checked (parseCriterionDescription "producer record consumed as hello")) HumanVerifiable JourneyRequired] []))
        let goal = created.objectiveId
        forM_ fixtureWorkers \name -> void (command goal ("adaptive-member-" <> name) (Command.GrantMember (RecordedAgent (actor name)) [Worker]))
        void (command goal "adaptive-coordinator-member" (Command.GrantMember (RecordedAgent (actor "coordinator")) [Coordinator]))
        now <- getCurrentTime
        let rootId = fixtureRootId "adaptive-delivery-root"
            limits = maybe (Map.fromList [(dimension, if dimension == R.ModelAttempts then R.Limited (checked (parseResourceAmount 48)) else R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (.limits) liveSettings
            envelope = R.Envelope limits (addUTCTime (maybe 1200 (fromIntegral . (.durationSeconds)) liveSettings) now)
        void (right =<< run env (Roots.enrollRoot rootId envelope))
        when live (Lazy.writeFile (prefix </> "adaptive-live-admission.json") (Aeson.encode (Aeson.object ["format" .= (1 :: Int), "admittedAt" .= now, "envelope" .= envelope, "rootId" .= rootId, "descriptors" .= Models.catalogDescriptors catalog, "authority" .= liveAuthorityIdentity q.config])))
        when transferring (rootReservationRace q rootId)
        when transferring do
          let select required = resolveExecutionSelection (assignmentIdFor "adaptive-alias-probe") catalog (defaultBinding stubModel emptyOptions) (Just (rolePolicy "consumer")) (Just (ExecutionRequest (Just (alias required)) Nothing Nothing)) Nothing Nothing (Just rootId) now
          void (right (select "consumer"))
          unless (either (const True) (const False) (select "producer")) (fail "consumer acquired a foreign role alias")
          Lazy.writeFile (prefix </> "adaptive-alias-policy.json") (Aeson.encode (Aeson.object ["rootId" .= rootId, "allowedAlias" .= ("consumer" :: Text), "forbiddenAlias" .= ("producer" :: Text), "admitted" .= True, "refused" .= True, "dispatches" .= (0 :: Int)]))
        void (command goal "adaptive-initial-assignment" (Command.SetAssignments [initialAssignment]))
        let request = checked (parseRequestKey "adaptive-delivery-native")
            job = addressedRunJob now (actor "coordinator") root.name AgentWorkflowRoute Aeson.Null (Ledger.httpRunKey root.name request) & #objective .~ Just (ObjectiveAssociation goal own) & #executionRootId .~ Just rootId
        void (right =<< Ledger.acceptObjectiveRunRequest settings store.pool job request (Ledger.callerAttribution callerName))
        let value = Saved goal job
        Lazy.writeFile (prefix </> "adaptive-state.json") (Aeson.encode value)
        pure value
      else right . Aeson.eitherDecodeStrict =<< Bytes.readFile (prefix </> "adaptive-state.json")
  baseBehavior <- if live then newBehaviorEnvFor Log.silentLogger q.config.behaviorProvider Nothing else newBehaviorEnv
  runtimeRef <- newIORef Nothing
  let resumedDefault = if transferring && stage /= "admit" then stubModel & #modelId .~ "forbidden-process-default" else baseBehavior.model
      readGoal = right =<< run env (O.readObjective owner saved.objectiveId)
      complete model context options = do
        unless (Model.modelId model `elem` ("adaptive" : fixtureWorkers)) (fail "process defaults escaped the admitted fixture aliases")
        response <- Provider.complete stubApiProvider model context options
        (output, calls) <-
          if Model.modelId model == "adaptive"
            then do
              journal <- run env (W.loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId saved.job) 0)
              admission <- case Map.lookup "adaptive-admission" journal of Just raw | Aeson.Success (Right value) <- Aeson.fromJSON @(Either ObjectiveError Admission) raw -> pure value; _ -> fail "adaptive native admission absent"
              generation <- run env (W.currentGeneration Generated.workflowName admission.run.runId)
              steps <- run env (W.loadStepIndex Generated.workflowName admission.run.runId generation)
              prepared <- case Map.lookup "decision-prepare-adapt" steps of Just raw | Aeson.Success (Right value) <- Aeson.fromJSON @(Either DecisionFailure PreparedDecision) raw -> pure value; _ -> fail "prepared adaptive input absent"
              input <- decode prepared.input
              fields <- right (Aeson.eitherDecodeStrict (Encoding.encodeUtf8 (input :: AdaptiveInput).checkpointJson))
              pinned <- decode =<< field "checkpoint" fields
              let current = (pinned :: CP.Checkpoint).objective
                  placements = [P.CreateAssignment (P.Placement (AssignmentDraft (key name) (checked (parseInstructions ("Deliver bounded " <> name))) [] (actor name) Pending Nothing (Just admission.organization.rootId) (Just admission.organization.cutoff)) (agent name) Nothing) | name <- names]
                  consumer = find ((== key "consumer") . (.definition.assignmentId)) current.assignments
                  reported = find ((== key "consumer") . (.assignmentId)) current.reportedResults
                  changes
                    | any ((== evidenceKey) . (.input.key)) current.evidence = [P.ProposeCompletion (P.IntegratedAcceptance current.revision current.instructionsRevision current.criteriaRevision [ref | entry <- current.evidence, Attestation {artifact = ref} <- [entry.input], entry.input.key == evidenceKey] [evidenceKey] [])]
                    | null [a | a <- current.assignments, a.definition.assignmentId /= own] = placements
                    | transferring, Just value <- consumer, value.definition.owner == actor "consumer", Just _ <- reported, Just workspace <- lookup (key "consumer") pinned.workspaces = [P.TransferAssignment (key "consumer") (agent "consumer-successor") workspace]
                    | Just value <- consumer, Just result <- reported, revisionNumber result.receipt.cursor <= 3 = [P.FollowUpContext (key "consumer") (Workers.WorkerInstruction (checked (Input.parseInstructionText "reconcile-v2: the retained producer emits version 2 at value.text; correct the consumer and commit")) current.revision value.revision current.criteriaRevision Nothing)]
                    | otherwise = [P.AwaitAssignments [own]]
                  proposal = P.Proposal V1 saved.objectiveId current.revision current.instructionsRevision current.criteriaRevision (Runtime.operationKey "decision" (Aeson.toJSON (admission.run, generation, current.revision))) (map (.input.key) current.evidence) (checked (parseCriterionDescription "Reflect on the retained producer schema finding")) (Just (checked (parseCriterionDescription "Worker local checks use different schema assumptions"))) (checked (parseCriterionDescription "Reconcile the consumer before integrating exact commits")) evidenceKey changes
              probed <- doesFileExist (prefix </> "adaptive-target-refusal.json")
              when (transferring && not probed && null [a | a <- current.assignments, a.definition.assignmentId /= own]) do
                runtime <- readIORef runtimeRef >>= maybe (fail "native adaptive runtime absent from refusal probe") pure
                let forbidden = proposal & #operationId .~ fixtureOperationId "adaptive-forbidden-target" & #changes .~ [P.CreateAssignment (P.Placement (AssignmentDraft (key "producer") (checked (parseInstructions "bounded forbidden-target probe")) [] (actor "producer") Pending Nothing (Just admission.organization.rootId) (Just admission.organization.cutoff)) (agent "forbidden-role") Nothing)]
                denied <- Runtime.accept runtime admission pinned forbidden
                unless (either (const True) (const False) denied) (fail "native checkpoint admitted an undeclared target")
                unchanged <- readGoal
                count <- run env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.worker_sessions" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
                unless (unchanged.revision == current.revision && count == 0) (fail "forbidden native target changed the checkpoint or dispatched a worker")
                Lazy.writeFile (prefix </> "adaptive-target-refusal.json") (Aeson.encode (Aeson.object ["rootId" .= admission.organization.rootId, "operationId" .= forbidden.operationId, "checkpointRevision" .= current.revision, "target" .= ("forbidden-role" :: Text), "refused" .= True, "sessionsAtCut" .= count, "unchangedCheckpoint" .= True]))
              pure (json (Aeson.object ["proposalJson" .= json proposal]), [])
            else do
              let name = Model.modelId model
                  repo = repositoryFor name
                  results = [result | Message.ToolResultMessage result <- Vector.toList context.messages]
                  correcting = "reconcile-v2" `Text.isInfixOf` Text.pack (show context)
                  replace path before after = Content.ToolCall ("replace-" <> path) "overlay__workspace-edit__replace" (Aeson.toJSON (Replacement (workspaceCoordinate path) (Just (contentDigest before)) after))
                  validate = Content.ToolCall "validate" "overlay__workspace-exec__validate" (Aeson.object ["rule" .= ("validate" :: Text)])
                  commit = Content.ToolCall "commit" "overlay__workspace-git__commit" (Aeson.toJSON (GitCommitRequest repo.base (workspaceCoordinate "feat: deliver bounded schema fixture")))
                  changes
                    | name `elem` ["consumer", "consumer-successor"] && correcting = [replace "contract.json" "{\"version\":1,\"path\":[\"text\"]}\n" "{\"version\":2,\"path\":[\"value\",\"text\"]}\n"]
                    | otherwise = [replace (if "-review" `Text.isSuffixOf` name then "review.txt" else "delivery.txt") "pending\n" "done\n"]
              unless (all (not . (.isError)) results) (fail "adaptive workspace tool refused")
              pure (json (Aeson.object ["finding" .= ("producer version 2 at value.text; consumer local sample is obsolete" :: Text), "results" .= results]), if null results then changes <> [validate] <> [commit | name `notElem` ["consumer", "consumer-successor"] || correcting] else [])
        let usage = Usage.zeroUsage & #availability .~ Just (Usage.UsageAvailability Set.empty False Set.empty) & #cost . #basis .~ Cost.providerReportedBasis
            message = response & #message . #content .~ Vector.fromList (if null calls then [Content.AssistantText (Content.TextContent output)] else map Content.AssistantToolCall calls)
            answer = if null calls then message else message & #message . #stopReason .~ ToolUse
            envelope = Aeson.object ["content" .= answer.message.content, "stop_reason" .= answer.message.stopReason, "usage" .= Evidence.usageEnvelope usage]
        Bytes.appendFile (prefix </> "adaptive-provider-calls") (Encoding.encodeUtf8 (Model.modelId model <> "\n"))
        pure (answer & #evidence %~ fmap (\value -> value & #usage .~ Evidence.Observed usage & #responseCommitment .~ Evidence.Observed (Evidence.commitmentDigest envelope)))
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
      selectedProviders = if live then liveProviders prefix (Decision.defaultDecisionServices catalog).providers else [provider]
  registry <- Provider.newProviderRegistryFrom selectedProviders
  http <- right =<< newSinkHttp (HttpLimits q.config.httpRequestMaxBytes q.config.httpResponseMaxBytes) (credentialsFromConfig q.config) (DanwaConfig "http://localhost:1" (declarationCoordinate "fixture"))
  let deps = Agent.AgentRunDeps env (baseBehavior & #model .~ resumedDefault & #providerRegistry .~ Just registry) (Decision.defaultDecisionServices catalog & #providers .~ selectedProviders) q.authorizer nativeHost.capabilities (Just nativeHost) (Just sessions) (Just objectives) Initiative.disabledInitiatives Observe.disabledObserve declarations (KizashiConfig "http://localhost:1" (declarationCoordinate "recipient")) (KawaConfig "http://localhost:1" (activityCoordinate "fixture")) (KanmonConfig "http://localhost:1") (DanwaConfig "http://localhost:1" (declarationCoordinate "fixture")) (ReiConfig Nothing) http (Agent.defaultAgentRunHooks & #afterStepBody .~ (\name -> when (stage == "crash" && name == W.StepName "adaptive-validation") (Bytes.writeFile (prefix </> "adaptive-crashed") "1\n" >> exitImmediately (ExitFailure 86)))) (autoApprovePolicy (checked (parseDuration 900))) Approval.defaultApprovalWorkflowEnv (checked (parseDuration 30)) defaultHarnessPolicy defaultDelegationBudget (StaticGrants defaultGrantTable) directory.handle (Routing.RoutingRuntime (\_ -> error "no routing") (\_ _ _ -> error "no routing")) Practice.unavailablePracticeReviewRuntime (Just store.pool) Log.silentLogger (\profile version -> pure (Left (UnknownProfile profile version)))
      -- Trusted integration tools are driven synchronously below. Their factual
      -- receipts still publish normal execution wakes. Supply only those two
      -- known starts to the normal driver so it can observe their stopped state;
      -- worker execution starts retain the production journal admission path.
      integrationStart workflow = listToMaybe [Driver.ExecutionStart execution | repo <- repos, let execution = Replay.executionIdFor (assignmentIdFor ("adaptive-integrate-" <> repo.name)), Replay.executionWorkflowId execution == workflow]
      executionRegistry = Map.singleton ExecutionDriver.workflowName (WorkflowDef \workflow -> Driver.executionWorkflow (Agent.executionRuntime deps) (integrationStart workflow))
      workflows = Agent.agentRunRegistry deps `Map.union` executionRegistry `Map.union` Adaptive.registry (Agent.adaptiveRuntime deps) `Map.union` Sessions.sessionRegistry (Agent.workerSessionRuntime deps)
  writeIORef runtimeRef (Agent.adaptiveRuntime deps)
  if stage == "admit"
    then do
      outcome <- right =<< Agent.runAgentRunWorkflow deps saved.job
      unless (outcome == W.Suspended) (fail "adaptive parent failed admission")
      putStrLn "PASS finite native adaptive objective admitted without completing it"
    else
      if stage == "unknown-observe"
        then observeUnknown q deps independentFence saved.objectiveId owner
        else do
          let pump 0 = fail "adaptive native fixture exceeded its bounded advances"
              pump remaining = do
                void (run env (resumeWorkflowsOnce (shikigamiWorkflowResumeOptions env 30) workflows))
                identifiers <- run env (runTransaction (Tx.statement () (preparable "SELECT execution_id FROM shikigami.executions ORDER BY execution_id" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
                forM_ identifiers \raw -> do
                  retained <- right =<< run env (Execution.inspectExecution (Replay.executionIdentity raw))
                  forM_ retained \(state, binding, _) -> forM_ state.activeOperation \operation -> do
                    attempts <- right =<< run env (Execution.inspectOperationAttempts operation)
                    forM_ (filter Attempt.logicalAttempt attempts) \attempt -> do
                      -- Guest realtime steps expire absolute guards. Observe a step
                      -- before a short validation; never disable that protection.
                      op <- right =<< run env (Execution.inspectOperation operation)
                      when (maybe False ((== "overlay__workspace-exec__validate") . executionCoordinateText . (.specification.name)) op) (void (readProcess "/usr/bin/timeout" ["40", prefix </> "root/bin/probe", "--await-clock-step"] ""))
                      let reference = Attempt.JobReference V1 state.executionId operation attempt.request.attemptId
                          loseFileReply = transferring && stage == "unknown-crash" && binding.identity == actor "consumer" && maybe False ((== "overlay__workspace-edit__replace") . executionCoordinateText . (.specification.name)) op
                      void (right =<< if loseFileReply then Executor.executeAcceptedAttempt (unknownRuntime prefix (Agent.executionRuntime deps)) binding.identity reference else Agent.executeAcceptedOperation deps binding.identity reference)
                current <- readGoal
                let ready = length current.reportedResults == 4 && any (\r -> r.assignmentId == key "consumer" && revisionNumber r.receipt.cursor > 3) current.reportedResults
                existing <- doesFileExist (prefix </> "adaptive-integrated.json")
                when ready do
                  integrated <-
                    if existing
                      then right . Aeson.eitherDecodeStrict =<< Bytes.readFile (prefix </> "adaptive-integrated.json")
                      else do
                        value <- integrate q nativeHost repos saved.job.executionRootId
                        Lazy.writeFile (prefix </> "adaptive-integrated.json") (Aeson.encode value)
                        pure value
                  let artifactRef = checked (parseArtifactRef ("pair:" <> versionedDigest "shikigami.adaptive-integrated-pair/1" integrated))
                  pair <- decode @[Aeson.Value] =<< field "repositories" integrated
                  exact <- forM pair \entry -> do
                    repository <- field "repository" entry
                    candidate <- field "combined" entry
                    pure (Aeson.object ["repository" .= repository, "combined" .= candidate])
                  forM_ names \name -> void (command saved.objectiveId ("adaptive-done-" <> name) (Command.RecordProgress (key name) Done [] []))
                  void (command saved.objectiveId "adaptive-exact-journey" (Command.RecordEvidence (key "consumer") (Attestation evidenceKey criterion artifactRef (checked (parseAttestationStatement (json exact))) JourneyObserved)))
                latest <- readGoal
                if isJust latest.proposed then pure latest else threadDelay 200000 >> pump (remaining - 1)
          starting <- readGoal
          proposed <- if starting.status == Completed then pure starting else pump (600 :: Int)
          unless (proposed.status == Completed) do
            unless (proposed.status == Open) (fail "model closed its own objective")
            when transferring (completionHold q owner proposed (fromMaybe (error "root") saved.job.executionRootId))
            void (command saved.objectiveId "adaptive-owner-accept" Command.AcceptCompletion)
          accepted <- readGoal
          unless (accepted.status == Completed) (fail "exact integrated objective did not close")
          rootUsage <- right =<< run env (Roots.inspectRoot (fromMaybe (error "root") saved.job.executionRootId))
          unless (rootUsage.active == noAttempts && rootUsage.unknown == noAttempts) (fail "native completion retained unsettled spending")
          counts <- run env (runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM shikigami.worker_sessions), (SELECT count(*) FROM shikigami.worker_session_messages), (SELECT count(*) FROM shikigami.worker_session_results)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))))
          unless (if live then let (sessionsCount, messagesCount, resultsCount) = counts in sessionsCount == 4 && messagesCount >= 5 && resultsCount >= 5 else counts == (4, 5, 5)) (fail "native recovery duplicated a worker, followup or result")
          calls <- Text.lines . Encoding.decodeUtf8 <$> Bytes.readFile (prefix </> "adaptive-provider-calls")
          unless (live || all (\name -> length (filter (== name) calls) == if name == "consumer" && not transferring then 4 else 2) fixtureWorkers) (fail "native worker provider calls repeated or omitted completed turns")
          liveCounts <- if live then Map.fromList <$> run env (runTransaction (Tx.statement () (preparable "SELECT s.state->'selection'->'descriptor'->>'alias', count(c.attempt_id) FROM shikigami.execution_selections s JOIN shikigami.execution_selection_calls c USING(assignment_id) GROUP BY 1" E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8)))))) else pure Map.empty
          integrated <- right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-integrated.json")
          ownership <- if transferring then right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-ownership-crashed.json") else pure Aeson.Null
          unknown <-
            if transferring
              then do
                observed <- right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-unknown-observed.json")
                cut <- right . Aeson.eitherDecodeStrict @UnknownCut =<< Bytes.readFile (prefix </> "adaptive-unknown-crashed.json")
                Just actual <- right =<< run env (Execution.inspectExecutionAttempt cut.reference.attemptId)
                unless (actual.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptSuperseded] && isJust actual.lateReceipt && isJust actual.outcome && actual.executionId == cut.reference.executionId && actual.operationId == cut.reference.operationId) (fail "unknown file outcome did not recover its original independent receipt")
                pure (Aeson.object ["observed" .= observed, "reference" .= cut.reference, "phase" .= actual.phase, "outcome" .= actual.outcome, "lateReceipt" .= actual.lateReceipt])
              else pure Aeson.Null
          race <- if transferring then right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-root-race.json") else pure Aeson.Null
          aliases <- if transferring then right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-alias-policy.json") else pure Aeson.Null
          targets <- if transferring then right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-target-refusal.json") else pure Aeson.Null
          completion <- if transferring then right . Aeson.eitherDecodeStrict @Aeson.Value =<< Bytes.readFile (prefix </> "adaptive-completion-hold.json") else pure Aeson.Null
          when transferring do
            assignment <- maybe (fail "accepted consumer missing") pure (find ((== key "consumer") . (.definition.assignmentId)) accepted.assignments)
            unless (assignment.definition.owner == actor "consumer-successor") (fail "successor did not own the accepted consumer artifact")
          Lazy.writeFile (prefix </> "adaptive-evidence.json") (Aeson.encode (Aeson.object ["format" .= (if live then 3 else if transferring then 2 else 1 :: Int), "ownership" .= ownership, "unknown" .= unknown, "completionHold" .= completion, "rootRace" .= race, "aliasPolicy" .= aliases, "targetRefusal" .= targets, "initialProcessDefault" .= Model.modelId baseBehavior.model, "resumedProcessDefault" .= Model.modelId resumedDefault, "rootId" .= saved.job.executionRootId, "objective" .= saved.objectiveId, "status" .= accepted.status, "root" .= rootUsage, "integrated" .= integrated, "reportedResults" .= accepted.reportedResults, "sessionMessageResultCounts" .= counts, "liveTransportCalls" .= (if live then length calls else 0), "providerCalls" .= (if live then liveCounts else Map.fromList [(name, fromIntegral (length (filter (== name) calls))) | name <- "adaptive" : fixtureWorkers])]))
          putStrLn "PASS native adaptive two-repository delivery closes only against the exact integrated journey"

-- Isolate the completion resource gate with an otherwise valid exact-artifact
-- proposal. This local accounting probe performs no mutable effect; the earlier
-- lost configured edit separately establishes actual mutable uncertainty.
completionHold :: Qualification -> O.ObjectiveHost -> Objective -> ExecutionRootId -> IO ()
completionHold q owner goal root = do
  (proposal, _) <- maybe (fail "completion probe has no integrated proposal") pure goal.proposed
  void (right (validateAcceptance goal proposal))
  now <- getCurrentTime
  current <- right =<< run q.env (Roots.inspectRoot root)
  let operation = R.OperationRequest (fixtureOperationId "adaptive-completion-hold") Nothing R.ToolOperation Map.empty (executionCoordinate "adaptive-completion-hold/1")
      attempt = R.AttemptRequest (fixtureAttemptId "adaptive-completion-hold") operation.operationId (Map.fromList [(dimension, checked (parseResourceAmount 1)) | dimension <- [R.ActiveWork, R.ToolAttempts]]) R.EnforcedCeiling
  void (right =<< run q.env (Roots.reserveOperation root current.revision operation now))
  void (right =<< run q.env (Roots.beginAttempt root current.revision attempt now))
  void (right =<< run q.env (Roots.settleAttempt root attempt.attemptId (R.UnknownUsage "local accounting gate probe; no dispatch")))
  held <- right =<< run q.env (Roots.inspectRoot root)
  denied <- run q.env (O.executeCommand owner goal.objectiveId goal.revision (fixtureOperationId "adaptive-owner-accept") Command.AcceptCompletion)
  unless (denied == Left ObjectiveUnresolved && held.active /= noAttempts && held.unknown /= noAttempts) (fail "valid integrated completion bypassed an unknown root hold")
  unchanged <- right =<< run q.env (O.readObjective owner goal.objectiveId)
  unless (unchanged == goal) (fail "refused completion changed its integrated proposal")
  void (right =<< run q.env (Roots.reconcileAttempt root attempt.attemptId Map.empty))
  Lazy.writeFile (q.prefix </> "adaptive-completion-hold.json") (Aeson.encode (Aeson.object ["rootId" .= root, "objective" .= goal.objectiveId, "revision" .= goal.revision, "validProposal" .= True, "refusal" .= ObjectiveUnresolved, "unchangedObjective" .= True, "activeAtCut" .= held.active, "unknownAtCut" .= held.unknown, "scope" .= ("resource admission only; no external dispatch" :: Text)]))

-- Two local control clients race the last active reservation at the same root
-- later used by the native objective. The accepted probe is settled without
-- external dispatch; it is not reported as a model or workspace tool call.
rootReservationRace :: Qualification -> ExecutionRootId -> IO ()
rootReservationRace q root = do
  current <- right =<< run q.env (Roots.inspectRoot root)
  let one = checked (parseResourceAmount 1)
      operation name = R.OperationRequest (fixtureOperationId ("adaptive-root-race-" <> name)) Nothing R.ToolOperation Map.empty (executionCoordinate "adaptive-root-race/1")
      attempt name = R.AttemptRequest (fixtureAttemptId ("adaptive-root-race-" <> name)) (operation name).operationId (Map.fromList [(R.ActiveWork, one), (R.ToolAttempts, one)]) R.EnforcedCeiling
  void (right =<< run q.env (Roots.setRootControl root current.revision R.ContinueWork (Just one)))
  narrowed <- right =<< run q.env (Roots.inspectRoot root)
  now <- getCurrentTime
  forM_ ["left", "right"] \name -> void (right =<< run q.env (Roots.reserveOperation root narrowed.revision (operation name) now))
  (left, rightResult) <- concurrently (run q.env (Roots.beginAttempt root narrowed.revision (attempt "left") now)) (run q.env (Roots.beginAttempt root narrowed.revision (attempt "right") now))
  winner <- case (left, rightResult) of
    (Right R.Accepted, Left (R.ResourceExhausted R.ActiveWork)) -> pure "left"
    (Left (R.ResourceExhausted R.ActiveWork), Right R.Accepted) -> pure "right"
    _ -> fail "shared root admitted other than one last-slot reservation"
  let loser = if winner == "left" then "right" else "left"
  held <- right =<< run q.env (Roots.inspectRoot root)
  missing <- right =<< run q.env (Roots.inspectAttempt root (attempt loser).attemptId)
  unless (attemptNumber held.active == 1 && missing == Nothing) (fail "losing root reservation published an actual attempt")
  void (right =<< run q.env (Roots.settleAttempt root (attempt winner).attemptId (R.KnownUsage Map.empty)))
  settled <- right =<< run q.env (Roots.inspectRoot root)
  void (right =<< run q.env (Roots.setRootControl root settled.revision R.ContinueWork Nothing))
  before <- right =<< run q.env (Roots.inspectRoot root)
  repeated <- right =<< run q.env (Roots.beginAttempt root narrowed.revision (attempt winner) now)
  after <- right =<< run q.env (Roots.inspectRoot root)
  unless (repeated == R.AlreadyAccepted && before == after && after.active == noAttempts && after.unknown == noAttempts) (fail "root reservation recovery changed held or settled usage")
  Lazy.writeFile (q.prefix </> "adaptive-root-race.json") (Aeson.encode (Aeson.object ["rootId" .= root, "winner" .= (attempt winner), "loser" .= (attempt loser), "accepted" .= (1 :: Int), "refused" .= (1 :: Int), "activeAtCut" .= held.active, "loserAbsent" .= True, "sameRootAfterRetry" .= True, "activeAfter" .= after.active, "unknownAfter" .= after.unknown, "scope" .= ("resource admission only; no external dispatch" :: Text)]))

-- Lose only the executor reply after the real configured file adapter returns.
-- Pause its independent publisher so expiry can expose the retained uncertainty;
-- no projection, provider receipt or journal is edited by the fault injector.
unknownRuntime :: FilePath -> Executor.ExecutionRuntime -> Executor.ExecutionRuntime
unknownRuntime prefix original@Executor.ExecutionRuntime {Executor.withTools = originalTools} =
  original
    { Executor.withTools = \snapshot dispatch wanted callback ->
        originalTools snapshot dispatch wanted \tools -> callback [Executor.BoundTool binding (wrapped snapshot dispatch tool) | Executor.BoundTool binding tool <- tools]
    }
  where
    wrapped :: Replay.ExecutionSnapshot -> DispatchContext -> Tool.SomeTool -> Tool.SomeTool
    wrapped snapshot dispatch tool = Tool.mkDynTool (Tool.someToolName tool) (Tool.someToolDescription tool) (Tool.someToolSchema tool) \arguments -> do
      result <- Tool.runErasedOutput tool arguments
      case result of
        Right output | not output.result.isError -> unsafeEff_ do
          admission <- maybe (fail "unknown file cut has no admitted workspace") pure snapshot.workspace
          let reference = Attempt.JobReference V1 snapshot.executionId dispatch.operation.operationId dispatch.attemptId
          Lazy.writeFile (prefix </> "adaptive-unknown-crashed.json") (Aeson.encode (UnknownCut reference snapshot.identity admission))
          callProcess "/usr/bin/systemctl" ["kill", "--kill-whom=all", "--signal=STOP", takeFileName prefix <> ".service"]
          exitImmediately (ExitFailure 92)
        _ -> pure ()
      pure result

observeUnknown :: Qualification -> Agent.AgentRunDeps -> Transfer.WorkspaceProvider -> ObjectiveId -> O.ObjectiveHost -> IO ()
observeUnknown q deps fence goal owner = do
  cut <- right . Aeson.eitherDecodeStrict @UnknownCut =<< Bytes.readFile (q.prefix </> "adaptive-unknown-crashed.json")
  let awaitExpiry 0 = fail "original file attempt did not reach its bounded expiry"
      awaitExpiry remaining = do
        Just attempt <- right =<< run q.env (Execution.inspectExecutionAttempt cut.reference.attemptId)
        now <- getCurrentTime
        if maybe False (now >=) attempt.expiresAt then pure () else threadDelay 1000000 >> awaitExpiry (remaining - 1)
  awaitExpiry (100 :: Int)
  void (right =<< Executor.executeAcceptedAttempt (Agent.executionRuntime deps) cut.identity cut.reference)
  held <- right =<< run q.env (Roots.inspectRoot cut.admission.rootId)
  unless (held.unknown /= noAttempts && held.active /= noAttempts) (fail "unknown mutable outcome lost its root hold")
  identifiers <- run q.env (runTransaction (Tx.statement () (preparable "SELECT session_id FROM shikigami.worker_sessions ORDER BY session_id" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
  sessions <- forM identifiers \raw -> right =<< run q.env (SessionStore.inspectSession (Input.workerSessionId raw))
  (state, _) <- maybe (fail "unknown file attempt has no retained worker session") pure (find (\(state, binding) -> state.owner == cut.identity && binding.rootId == cut.admission.rootId) [entry | Just entry <- sessions])
  let successor = actor "consumer-successor"
      successorEpoch = advanceRevision state.epoch
  authorized <- fence.admitWrite cut.admission.workspace state.sessionId cut.identity state.epoch (fixtureOperationId "adaptive-unknown-owner-control")
  unless (authorized == Right ()) (fail "unknown write probe has no passing original-owner admission control")
  refused <- fence.admitWrite cut.admission.workspace state.sessionId successor successorEpoch (fixtureOperationId "adaptive-unknown-successor-write")
  unless (either (const True) (const False) refused) (fail "unknown active assignment admitted a successor write")
  stillHeld <- right =<< run q.env (Roots.inspectRoot cut.admission.rootId)
  unless (stillHeld == held) (fail "unknown write probe did not preserve its root hold")
  current <- right =<< run q.env (O.readObjective owner goal)
  completion <- run q.env (O.executeCommand owner goal current.revision (fixtureOperationId "adaptive-unknown-completion") Command.AcceptCompletion)
  unless (current.status == Open && either (const True) (const False) completion) (fail "unknown active work completed its objective")
  Lazy.writeFile (q.prefix </> "adaptive-unknown-observed.json") (Aeson.encode (Aeson.object ["rootId" .= cut.admission.rootId, "reference" .= cut.reference, "root" .= held, "workspace" .= cut.admission.workspace, "sessionId" .= state.sessionId, "phase" .= state.phase, "successor" .= successor, "successorEpoch" .= successorEpoch, "probe" .= ("production workspace owner; publisher paused" :: Text), "originalOwnerAdmitted" .= True, "sameRootAfterProbe" .= True, "successorWriteDenied" .= True, "completionDenied" .= True, "status" .= current.status]))
  putStrLn "PASS unknown mutable work retains its root hold and refuses successor admission and completion"

-- Native integration targets are separate configured workspaces under the same
-- root. Every replacement, validation and local commit remains accepted work.
integrate :: Qualification -> WorkspaceHost -> [Repo] -> Maybe ExecutionRootId -> IO Aeson.Value
integrate original host repos suppliedRoot = do
  root <- maybe (fail "integration root absent") pure suppliedRoot
  let q = original & #host .~ host
  identifiers <- run q.env (runTransaction (Tx.statement () (preparable "SELECT operation_id FROM shikigami.workspace_effects WHERE kind='git' ORDER BY operation_id" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
  sources <- forM identifiers \raw -> right =<< run q.env (runTransaction (Git.inspectRegisteredGitTx (checked (parseOperationId raw))))
  combined <- forM repos \repo -> do
    let retained = [(binding, record, candidate) | Just (binding, record) <- sources, binding.request.rootId == root, binding.repository == repo.repository, record.phase == GitApplied, Just candidate <- [record.candidate]]
        artifacts = [Integration.Artifact record.operation.operationId (workspaceBindingDigest binding) binding.base candidate.result | (binding, record, candidate) <- retained]
    unless (length artifacts == 2) (fail "two exact native worker commits required per repository")
    now <- getCurrentTime
    session <- genSessionId
    let role = "integrate-" <> repo.name
        runId = "adaptive-" <> role
    selection <- right (resolveExecutionSelection (assignmentIdFor runId) (checked (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just root) now)
    admission <- right =<< host.load (SkillAssignment (W.WorkflowId runId) (agent role) (actor "coordinator") session selection Nothing emptyResolvedCapabilitySet (Right defaultHarnessPolicy) (SkillDir "fixture") (fail "integration host cannot dispatch a model"))
    prepared <- prepareToolsFor (agent role) q.env q.authorizer q.current q.client admission [("overlay__workspace-integrate__plan", Aeson.toJSON (Integration.RequestInput repo.base artifacts))]
    (planned, outputs) <- runTools q prepared
    proposal <- case outputs of [value] -> pure value; _ -> fail "one integration proposal required"
    conflicts <- field "conflicts" proposal
    unless (conflicts == Aeson.toJSON ([] :: [Text])) (fail "exact native artifacts conflict")
    replacements <- decode @[Replacement] =<< field "replacements" proposal
    next <- continueTools q.env q.current planned (map (\replacement -> ("overlay__workspace-edit__replace", Aeson.toJSON replacement)) replacements <> [("overlay__workspace-exec__validate", Aeson.object ["rule" .= ("validate" :: Text)]), ("overlay__workspace-git__commit", Aeson.toJSON (GitCommitRequest repo.base (workspaceCoordinate "feat: integrate exact retained artifacts")))])
    (committed, results) <- runTools q next
    validation <- decode @ProcessReceipt (results !! length replacements)
    unless (successful validation) (fail "integrated repository validation failed")
    Just (binding, record) <- right =<< run q.env (runTransaction (Git.inspectRegisteredGitTx committed.reference.operationId))
    candidate <- maybe (fail "integrated commit absent") pure record.candidate
    expected <- field "tree" proposal
    unless (record.phase == GitApplied && expected == Aeson.toJSON candidate.tree) (fail "integrated tree differs from planned tree")
    -- This trusted controller consumes accepted tool outcomes without a final
    -- model turn. Explicitly stop that fixture execution; its factual Git and
    -- validation receipts remain authoritative for the separate owner check.
    Just (state, _, _) <- right =<< run q.env (Execution.inspectExecution committed.snapshot.executionId)
    void (right =<< run q.env (Execution.stopExecution committed.snapshot.identity committed.snapshot.executionId state.revision Replay.StopAsFailure (Replay.ExecutionPolicyRefused "trusted fixture integration tools completed")))
    let metadata = workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding
        path = if repo.name == "producer" then "record.json" else "contract.json"
    entries <- right =<< Objects.readFlatTree metadata candidate.tree
    entry <- maybe (fail "integrated journey blob absent") pure (find ((== workspaceCoordinate path) . (.name)) entries)
    bytes <- right =<< Objects.readBlob metadata 4096 entry.objectId
    Bytes.writeFile (q.prefix </> ("adaptive-" <> Text.unpack path)) bytes
    pure (Aeson.object ["repository" .= repo.repository, "base" .= repo.base, "workers" .= artifacts, "combined" .= candidate, "validation" .= validation])
  let journey = "/var/lib/shikigami-workspace-fixture-code/tests/adaptive-delivery/journey.py"
      producer = q.prefix </> "adaptive-record.json"
      consumer = q.prefix </> "adaptive-contract.json"
  (code, output, _) <- readProcessWithExitCode "/usr/bin/timeout" ["10", "/usr/bin/python3", "-I", journey, "--producer", producer, "--consumer", consumer] ""
  unless (code == ExitSuccess && output == "combined journey passed: hello\n") (fail "exact combined pair journey failed")
  pure (Aeson.object ["repositories" .= combined, "journey" .= Aeson.object ["exitCode" .= (0 :: Int), "output" .= output, "scope" .= ("immutable blobs from the two retained combined trees" :: Text)]])

field :: Aeson.Key -> Aeson.Value -> IO Aeson.Value
field name (Aeson.Object fields) = maybe (fail "native evidence field missing") pure (KeyMap.lookup name fields)
field _ _ = fail "native evidence object missing"

decode :: (Aeson.FromJSON a) => Aeson.Value -> IO a
decode value = case Aeson.fromJSON value of Aeson.Success result -> pure result; Aeson.Error _ -> fail "native evidence codec refused"

-- Task guidance is part of the pinned declaration, not a scripted response.
liveCoordinatorInstructions :: Text
liveCoordinatorInstructions = "Deliver the finite producer/consumer fixture through exactly four worker assignments named producer, producer-review, consumer, consumer-review, targeting the same-named admitted agents. Use each target's pinned principal, root and cutoff. Producer emits version 2 at value.text; consumer starts at version 1 at text. First ask producer and both review roles to change their own delivery.txt or review.txt from pending to done, validate and commit. Ask consumer to change delivery.txt from pending to done and validate, then report its old schema without committing yet. After findings arrive, FollowUpContext the same consumer assignment to reconcile contract.json to version 2 with path [value,text], validate and commit both changes. Each worker starts with delivery.txt and review.txt containing pending followed by a newline. Give exact bounded instructions. Do not alter checks or other files. Await assignments when no new adaptation is justified. The trusted integrator will combine each delivery/review commit pair, run the exact two-tree journey and record exact-pair-journey evidence. Only after that evidence exists, ProposeCompletion with the current criteria and exact artifact/evidence references. Never accept completion yourself. Use the supplied closed proposal vocabulary and copy proposalCoordinates exactly."

-- This file contains no credentials; it is copied beside private AppConfig.
data LiveSettings = LiveSettings {durationSeconds :: !Int, limits :: !R.Limits}
  deriving stock (Eq, Generic)
  deriving anyclass (Aeson.ToJSON)

instance Aeson.FromJSON LiveSettings where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

readLiveSettings :: FilePath -> IO LiveSettings
readLiveSettings path = do
  bytes <- Bytes.readFile path
  unless (Bytes.length bytes <= 65536) (fail "live limits exceed their bound")
  either (const (fail "invalid live limits")) pure (Aeson.eitherDecodeStrict bytes)

validateLiveConfig :: AppConfig -> LiveSettings -> [Text] -> IO ModelCatalog
validateLiveConfig config settings roles = do
  unless (settings.durationSeconds > 0 && settings.durationSeconds <= 1200) (fail "live duration must be between one and 1200 seconds")
  unless (Map.keysSet settings.limits == Map.keysSet (Map.fromList [(d, ()) | d <- [minBound .. maxBound]])) (fail "live root must declare every dimension")
  forM_ [minBound .. maxBound] \dimension -> case (dimension, Map.lookup dimension settings.limits) of
    (R.CostMicroUsd, Just R.ExplicitlyUnbounded) -> pure ()
    (R.CostMicroUsd, _) -> fail "HTTP invoice ceilings cannot be enforced"
    (_, Just (R.Limited amount)) | amountUnits amount > 0 -> pure ()
    _ -> fail "live enforceable limits must be finite and positive"
  case config.actionAuthorization of
    KikanActionAuthorization {kikanBaseUrl, shomeiBaseUrl, callerId}
      | all (Text.isPrefixOf "https://") [kikanBaseUrl, shomeiBaseUrl], callerId /= "workspace-fixture" -> pure ()
    _ -> fail "live qualification requires explicit production authorization over HTTPS"
  case config.behaviorProvider of
    UseStub -> fail "live qualification refuses the stub behavior provider"
    selection -> unless (either (const False) (const True) (validateProviderSelection selection)) (fail "live behavior provider is incompatible")
  catalog <- either (const (fail "live catalog is invalid")) pure config.decisionModelCatalog
  let descriptors = catalogDescriptors catalog
  unless (length descriptors == length roles && all (\role -> any ((== role) . modelAliasText . (.alias)) descriptors) roles) (fail "live catalog must contain exactly the admitted roles")
  forM_ descriptors \descriptor -> do
    binding <- either (const (fail "live binding unavailable")) pure (pinnedBinding catalog descriptor)
    let model = bindingModel binding
        options = bindingOptions binding
    unless
      ( Model.api model `elem` [AnthropicMessages, OpenAIChatCompletions, OpenAIResponses]
          && providerCoordinateText descriptor.endpointClass == "https"
          && not ("adaptive-fixture-" `Text.isPrefixOf` modelRegistrationText descriptor.bindingId)
          && isJust (bindingCredential binding)
          && maybe False (> 0) (Options.maxTokens options)
          && maybe False (\ms -> ms > 0 && ms <= settings.durationSeconds * 1000) (Options.timeoutMs options)
      )
      (fail "live binding requires HTTP credentials and explicit output/time ceilings")
  pure catalog

-- Preserve provider responses/evidence untouched. The private journal counts
-- entry into the real handler; it never substitutes usage or response content.
liveProviders :: FilePath -> [Provider.ApiProvider] -> [Provider.ApiProvider]
liveProviders prefix = map wrap . filter (\p -> p.apiTag `elem` [AnthropicMessages, OpenAIChatCompletions, OpenAIResponses])
  where
    wrap provider = provider & #complete .~ complete & #stream .~ liftCompleteToStream complete
      where
        complete model context options = do
          unless (isJust (Options.evidence options)) (fail "live model dispatch lacks admitted evidence context")
          let requested = Aeson.object ["tuple" .= providerCallFor model options, "evidenceRequest" .= Options.evidence options]
          Lazy.appendFile (prefix </> "adaptive-live-dispatches.jsonl") (Aeson.encode requested <> "\n")
          response <- Provider.complete provider model context options
          Lazy.appendFile (prefix </> "adaptive-provider-calls") (Aeson.encode (Aeson.object ["tuple" .= providerCallFor model options, "evidenceRequest" .= Options.evidence options, "providerCallId" .= fmap (.callId) response.evidence, "maxTokens" .= Options.maxTokens options, "timeoutMs" .= Options.timeoutMs options]) <> "\n")
          pure response

recordAuthority :: FilePath -> ActionAuthorizer -> ActionAuthorizer
recordAuthority prefix original =
  original
    { authorize = \principal action -> do
        result <- original.authorize principal action
        forM_ result \decision -> Lazy.appendFile (prefix </> "adaptive-live-authority.jsonl") (Aeson.encode (Aeson.object ["principal" .= principal, "resource" .= decision.authorizedResource, "requestId" .= decision.authorizationRequestId, "checkedAt" .= decision.checkedAt, "schemaHash" .= decision.schemaHash, "expiresAt" .= decision.expiresAt]) <> "\n")
        pure result
    }

livePreflight :: FilePath -> FilePath -> IO ()
livePreflight configPath limitsPath = do
  settings <- readLiveSettings limitsPath
  config <- runAppConfig AdminRole (ConfigOptions [configPath] [] [] NoDiagnostic)
  void (validateLiveConfig config settings ["adaptive", "producer", "producer-review", "consumer", "consumer-review"])
  built <- buildConfiguredActionAuthorizer Log.silentLogger config
  either (const (fail "live authorizer configuration refused")) (const (putStrLn "PASS live configuration preflight; no model dispatch")) built

-- Exercise the actual CLI, including environment isolation and secret redaction.
-- The shared input contains only fake credentials and reserved invalid endpoints.
liveControls :: FilePath -> IO ()
liveControls fixturePath = do
  fixture <- Lazy.readFile fixturePath >>= either fail pure . Aeson.eitherDecode
  application <- field "application" fixture
  settings <- field "settings" fixture
  executable <- getExecutablePath
  environment <- getEnvironment
  let injected = [("OPENAI_API_KEY", "PRIVATE_MARKER"), ("SHIKIGAMI_BEHAVIOR_PROVIDER", "stub")]
      childEnvironment = injected <> filter (\(variable, _) -> variable `notElem` map fst injected) environment
      edit [] f value = f value
      edit (member : members) f (Aeson.Object object) = case KeyMap.lookup member object of
        Just value -> Aeson.Object (KeyMap.insert member (edit members f value) object)
        Nothing -> error "missing live control fixture key"
      edit _ _ _ = error "invalid live control fixture path"
      first f (Aeson.Array values) = Aeson.Array (Vector.imap (\index value -> if index == 0 then f value else value) values)
      first _ _ = error "invalid live control model array"
      remove member (Aeson.Object object) = Aeson.Object (KeyMap.delete member object)
      remove _ _ = error "invalid live control object"
      dropRole (Aeson.Array values) = Aeson.Array (Vector.init values)
      dropRole _ = error "invalid live control role array"
      limit dimension policy = edit ["limits"] \case
        Aeson.Array values ->
          Aeson.Array
            ( fmap
                ( \value -> case value of
                    Aeson.Array pair | Vector.head pair == Aeson.String dimension -> Aeson.toJSON [Aeson.String dimension, policy]
                    _ -> value
                )
                values
            )
        _ -> error "invalid live control limits"
      unbounded = Aeson.object ["tag" .= ("ExplicitlyUnbounded" :: Text)]
      cases =
        [ ("configured HTTP", id, id, True),
          ("stub behavior", edit ["behavior", "provider"] (const (Aeson.String "stub")), id, False),
          ("disabled authority", edit ["authorization", "actions", "mode"] (const (Aeson.String "disabled")), id, False),
          ("unbounded tokens", id, limit "Tokens" unbounded, False),
          ("finite invoice ceiling", id, limit "CostMicroUsd" (Aeson.object ["tag" .= ("Limited" :: Text), "contents" .= (1 :: Int)]), False),
          ("missing role", edit ["behavior", "decisionModels"] dropRole, id, False),
          ("missing key", edit ["credentials", "providers", "openai"] (remove "api_key"), id, False),
          ("missing timeout", edit ["behavior", "decisionModels"] (first (remove "timeout_ms")), id, False)
        ]
      temporary = do
        directory <- getTemporaryDirectory
        (path, handle) <- openBinaryTempFile directory "shikigami-live-control.json"
        hClose handle
        pure path
  bracket temporary removeFile \appPath -> bracket temporary removeFile \limitsPath ->
    forM_ cases \(name, changeApp, changeLimits, accepted) -> do
      Lazy.writeFile appPath (Aeson.encode (changeApp application))
      Lazy.writeFile limitsPath (Aeson.encode (changeLimits settings))
      result <- timeout 20000000 (readCreateProcessWithExitCode ((proc executable ["adaptive-live-preflight", appPath, limitsPath]) {Process.env = Just childEnvironment}) "")
      case result of
        Just (status, output, errors) -> do
          unless ((status == ExitSuccess) == accepted) (fail (name <> ": unexpected preflight status " <> show status))
          when ("PRIVATE_MARKER" `Text.isInfixOf` Text.pack (output <> errors)) (fail (name <> ": secret leaked"))
        Nothing -> fail (name <> ": preflight timed out")
  putStrLn ("PASS " <> show (length cases) <> " native live preflight controls; no model dispatch")

liveAuthorityIdentity :: AppConfig -> Aeson.Value
liveAuthorityIdentity config = case config.actionAuthorization of
  KikanActionAuthorization {kikanBaseUrl, shomeiBaseUrl, callerId} -> Aeson.object ["kikanBaseUrl" .= kikanBaseUrl, "shomeiBaseUrl" .= shomeiBaseUrl, "callerId" .= callerId]
  _ -> Aeson.Null
